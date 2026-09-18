import ast
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / ".github/workflows/deploy-workload.yml").read_text()
DEPLOY = SOURCE.split("\n  deploy:\n", 1)[1]


def condition(expression, context):
    expression = re.sub(r"\b(?:steps|github)\.[\w.-]+", lambda match: repr(context.get(match[0], "")), expression)
    node = ast.parse(expression.replace("&&", " and ").replace("||", " or "), mode="eval").body

    def evaluate(value):
        if isinstance(value, ast.Constant):
            return value.value
        if isinstance(value, ast.BoolOp):
            values = [evaluate(item) for item in value.values]
            return all(values) if isinstance(value.op, ast.And) else any(values)
        if isinstance(value, ast.Compare) and len(value.ops) == 1:
            left, right = evaluate(value.left), evaluate(value.comparators[0])
            if isinstance(value.ops[0], ast.Eq):
                return left == right
            if isinstance(value.ops[0], ast.NotEq):
                return left != right
        raise AssertionError(f"Unexpected lifecycle condition: {expression}")

    return evaluate(node)


def step(name):
    return DEPLOY.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]


class DeploymentGatingTests(unittest.TestCase):
    def allowed(self, name, context):
        expression = re.search(r"^        if: (.+)$", step(name), re.MULTILINE)
        self.assertIsNotNone(expression, f"{name} is missing its safety gate")
        return condition(expression[1], context)

    def test_stopped_gateways_cannot_reconcile_recreate_rotate_keys_or_bootstrap(self):
        policy = re.search(r"RECONCILE: \$\{\{ (.+) \}\}", DEPLOY)[1]
        names = [
            "Ensure landing-zone deployed", "Resolve landing-zone outputs",
            "Resolve blessed image version", "Check VM state", "Delete VM if image changed",
            "Generate agenix host key and customData (Option A)",
            "Deploy Infrastructure", "Show Outputs", "Wait for waagent ready",
            "Write host key and bootstrap token via run-command",
        ]
        for power in ("stopped", "deallocated", "running", "missing"):
            for upstream in ("", "image-bake"):
                context = {
                    "steps.power-state.outputs.power_state": power,
                    "github.event.workflow_run.name": upstream,
                    "steps.resolve-image.outputs.image_ready": "true",
                }
                reconcile = condition(policy, context)
                context["steps.policy.outputs.reconcile"] = str(reconcile).lower()
                check_vm = self.allowed("Check VM state", context)
                context["steps.vm-state.outputs.image_changed"] = "true" if check_vm else ""
                context["steps.vm-state.outputs.vm_exists"] = "true" if check_vm else ""
                expected = power == "missing" or (power == "running" and upstream != "image-bake")
                for name in names:
                    with self.subTest(power=power, upstream=upstream, step=name):
                        self.assertEqual(self.allowed(name, context), expected)

    def test_pending_image_cannot_rotate_keys_or_submit_vm_deployment(self):
        context = {
            "steps.policy.outputs.reconcile": "true",
            "steps.resolve-image.outputs.image_ready": "false",
        }
        for name in ("Check VM state", "Generate agenix host key and customData (Option A)", "Deploy Infrastructure"):
            self.assertFalse(self.allowed(name, context), name)

    def test_all_regional_mutation_jobs_share_one_lock_namespace(self):
        for group in ("cleanup-disabled-regions", "cleanup-stale-hosts", "deploy"):
            job = SOURCE.split(f"\n  {group}:\n", 1)[1]
            job = re.split(r"\n  [a-z][a-z-]*:\n", job, maxsplit=1)[0]
            self.assertIn("group: region-${{ matrix.location }}", job)
        landing = (ROOT / ".github/workflows/landing-zone.yml").read_text()
        self.assertIn("group: region-${{ matrix.location }}", landing)
        gallery = SOURCE.split("\n  cleanup-gallery-replicas:\n", 1)[1].split("\n  discover-stale-hosts:", 1)[0]
        self.assertIn("group: image-bake", gallery)

    def test_superseded_or_failed_upstream_cannot_restore_retired_regions(self):
        self.assertIn("github.event.workflow_run.conclusion == 'success'", SOURCE)
        self.assertIn("github.event.workflow_run.head_repository.id == github.repository_id", SOURCE)
        self.assertIn('if [ "$SOURCE_SHA" = "$CURRENT_SHA" ]', SOURCE)
        self.assertEqual(SOURCE.count("if: needs.validate.outputs.current != 'false'"), 3)


class RegionalCleanupTests(unittest.TestCase):
    def test_deletion_targets_exactly_three_regional_groups_not_shared_services(self):
        script = SOURCE.split("      - name: Delete regional resource groups\n", 1)[1].split("\n  cleanup-gallery-replicas:", 1)[0]
        script = textwrap.dedent(script.split("        run: |\n", 1)[1]).replace("${{ env.PROJECT_NAME }}", "plaz")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            az = root / "az"
            log = root / "calls"
            az.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n'
                'case "$1 $2" in\n'
                ' "group exists") echo true;;\n'
                ' "group delete"|"group wait") exit 0;;\n'
                ' *) exit 99;;\nesac\n'
            )
            az.chmod(0o700)
            result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=5, env={
                **os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                "CLEANUP_LOCATION": "southeastasia", "CALLS": str(log),
            })
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text().splitlines()
            deletions = [call for call in calls if call.startswith("group delete ")]
            self.assertEqual(deletions, [
                f"group delete --name rg-plaz-{kind}-southeastasia --yes --no-wait"
                for kind in ("compute", "network", "monitoring")
            ])
            self.assertEqual(len([call for call in calls if call.startswith("group wait ")]), 3)
            self.assertNotIn("gallery", "\n".join(calls))
            self.assertNotIn("keyvault", "\n".join(calls))

    def test_primary_removal_has_explicit_pre_mutation_guard(self):
        discovery = SOURCE.split("\n  discover-stale-regions:\n", 1)[1].split("\n  cleanup-disabled-regions:", 1)[0]
        guard = "if git cat-file -e " + discovery.split("          if git cat-file -e ", 2)[2]
        guard = textwrap.dedent(guard.split("          # Fail fast", 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            git = Path(directory) / "git"
            git.write_text(
                '#!/bin/sh\nif [ "$1" = show ]; then\n'
                """echo '{"regions":[{"location":"southcentralus","primary":true}]}'\nfi\nexit 0\n"""
            )
            git.chmod(0o700)
            for location, expected in (("southcentralus", 1), ("southeastasia", 0)):
                with self.subTest(location=location):
                    result = subprocess.run(["bash", "-euc", guard], capture_output=True, text=True, timeout=5, env={
                        **os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                        "BEFORE_SHA": "fixture", "PREVIOUSLY_ENABLED_NOW_DISABLED": location,
                    })
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

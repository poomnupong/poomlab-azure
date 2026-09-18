import ast
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/copilot-auto-retry.yml"


def evaluate_guard(node, context):
    """Evaluate only the expression constructs used in the actual job guard."""
    if isinstance(node, ast.Expression):
        return evaluate_guard(node.body, context)
    if isinstance(node, ast.Name) and node.id == "github":
        return context
    if isinstance(node, ast.Attribute):
        value = evaluate_guard(node.value, context)
        return value.get(node.attr) if isinstance(value, dict) else None
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.BoolOp):
        values = (bool(evaluate_guard(value, context)) for value in node.values)
        return all(values) if isinstance(node.op, ast.And) else any(values)
    if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], ast.Eq):
        left = evaluate_guard(node.left, context)
        right = evaluate_guard(node.comparators[0], context)
        if isinstance(left, str) and isinstance(right, str):
            return left.casefold() == right.casefold()
        return left == right
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "startsWith":
        value, prefix = (evaluate_guard(arg, context) for arg in node.args)
        return str(value or "").casefold().startswith(prefix.casefold())
    raise AssertionError(f"Unsupported guard construct: {ast.dump(node)}")


class RetryGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text()
        match = re.search(r"    if: \|\n((?:      .*\n)+)", cls.source)
        assert match is not None, "Missing workflow job guard"
        expression = " ".join(line.strip() for line in match.group(1).splitlines())
        cls.guard = ast.parse(expression.replace("&&", " and ").replace("||", " or "), mode="eval")

    def setUp(self):
        self.event = {
            "repository": {"id": 42},
            "workflow_run": {
                "conclusion": "failure",
                "head_repository": {"id": 42},
                "head_branch": "main",
            },
        }

    def allowed(self, event):
        return bool(evaluate_guard(self.guard, {"event": event}))

    def test_same_repo_main_and_copilot_failures_are_admitted(self):
        for branch in ("main", "copilot/fix-auth"):
            with self.subTest(branch=branch):
                self.event["workflow_run"]["head_branch"] = branch
                self.assertTrue(self.allowed(self.event))

    def test_other_branches_are_rejected(self):
        for branch in ("feature/change", "main-extra", "copilot-other/fix"):
            with self.subTest(branch=branch):
                self.event["workflow_run"]["head_branch"] = branch
                self.assertFalse(self.allowed(self.event))

    def test_non_failures_are_rejected(self):
        for conclusion in ("success", "skipped", "cancelled", None):
            with self.subTest(conclusion=conclusion):
                self.event["workflow_run"]["conclusion"] = conclusion
                self.assertFalse(self.allowed(self.event))

    def test_fork_and_missing_identities_are_rejected(self):
        for repository in ({"id": 99}, {}, None):
            with self.subTest(repository=repository):
                self.event["workflow_run"]["head_repository"] = repository
                self.assertFalse(self.allowed(self.event))
        self.assertFalse(self.allowed({"repository": {}, "workflow_run": {}}))
        self.assertFalse(self.allowed({}))

    def test_flat_repository_id_does_not_admit_a_fork(self):
        event = copy.deepcopy(self.event)
        event["workflow_run"]["head_repository"] = {"id": 99}
        event["workflow_run"]["head_repository_id"] = 42
        self.assertFalse(self.allowed(event))

    def test_watched_workflows_and_retry_cap_remain_bounded(self):
        names = re.search(r"    workflows:\n((?:      - .*\n)+)", self.source).group(1)
        self.assertEqual(
            re.findall(r'"([^"]+)"', names),
            ["ci-pr", "image-bake", "global", "landing-zone", "deploy-workload"],
        )
        self.assertIn('if [ "${COUNT}" -ge 5 ]', self.source)
        self.assertIn("if ! ISSUES=$(gh issue list", self.source)
        self.assertIn("refusing to bypass the retry cap", self.source)
        self.assertNotIn("defaulting to 0", self.source)

    def run_count_step(self, titles, gh_exit="0"):
        section = self.source.split("      - name: Count existing retry issues for this branch", 1)[1]
        section = section.split("      # ----------------------------------------------------------------", 1)[0]
        script = textwrap.dedent(section.split("        run: |\n", 1)[1])
        script = script.replace("${{ github.repository }}", "owner/repo")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / "gh"
            gh.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$ISSUES_FIXTURE"\nexit "$GH_EXIT"\n'
            )
            gh.chmod(0o700)
            output = root / "output"
            env = {
                **os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                "BRANCH": "copilot/fix", "GH_TOKEN": "fixture",
                "GH_EXIT": gh_exit, "GITHUB_OUTPUT": str(output),
                "ISSUES_FIXTURE": json.dumps([{"title": title} for title in titles]),
            }
            result = subprocess.run(
                ["bash", "-c", script], env=env, capture_output=True, text=True, timeout=10
            )
            return result, output.read_text() if output.exists() else ""

    def test_actual_count_step_respects_five_issue_threshold_and_exact_branch(self):
        for count in (0, 4, 5, 6):
            with self.subTest(count=count):
                titles = [f"[Auto-Retry {i}] failure on `copilot/fix`" for i in range(count)]
                titles += ["failure on `copilot/fix-more`", "failure on `main`"]
                result, output = self.run_count_step(titles)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, f"count={count}\n")
                self.assertEqual("Max retries (5)" in result.stdout, count >= 5)

    def test_retry_history_failure_stops_instead_of_emitting_zero(self):
        result, output = self.run_count_step([], gh_exit="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to bypass the retry cap", result.stdout)
        self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main()

"""Offline registry, Azure power protocol, and workflow safety regressions."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import unittest
from unittest.mock import MagicMock, mock_open, patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gateway_power", ROOT / ".github/scripts/gateway-power.py")
power = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(power)
SUBSCRIPTION = "00000000-0000-0000-0000-000000000001"


def region(env="plaz", location="southcentralus", gateway="gw1-scus"):
    return dict(env=env, location=location, gateway=gateway, regionCode="scus",
                enabled=True, primary=env == "plaz")


def secondary():
    return region("plaz-sea", "southeastasia", "gw1-sea")


def statuses(state="running", provisioning="succeeded"):
    return json.dumps([
        {"code": f"ProvisioningState/{provisioning}", "displayStatus": "Ignored"},
        {"code": f"PowerState/{state}", "displayStatus": "Ignored"},
    ])


def response(stdout="", stderr="", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class RegistryTests(unittest.TestCase):
    def validate(self, entries, *, missing=None, project="plaz"):
        with patch.object(Path, "read_text", return_value=json.dumps({"regions": entries})), \
                patch.object(Path, "is_file", autospec=True,
                             side_effect=lambda path: missing is None or missing not in str(path)):
            return power.validate_registry(ROOT / "infra/regions.json", project)

    def test_add_remove_and_disable_regions(self):
        for entries, count in (([region()], 1), ([region(), secondary()], 2)):
            with self.subTest(count=count):
                self.assertEqual(len(self.validate(entries)), count)
        entries = [region(), dict(secondary(), enabled=False)]
        self.assertEqual(len(self.validate(entries, missing="plaz-sea")), 2)
        self.assertEqual(len(self.validate(entries, missing="gw1-sea")), 2)

    def test_required_files_checked_only_for_enabled_members(self):
        for name in ("plaz-landing-zone.bicepparam", "plaz-workload.bicepparam",
                     "gw1-scus/default.nix", "gw1-scus/hardware.nix"):
            with self.subTest(name=name), self.assertRaisesRegex(power.PowerError, "requires"):
                self.validate([region()], missing=name)

    def test_rejects_unsafe_names_and_reserved_environment(self):
        for field in ("env", "gateway", "location", "regionCode"):
            for value in ("", "ALL", "../plaz", "a/b", "-plaz", "plaz-", "a--b",
                          "plaz\nx", "plaz x", "pláz", "$(start)", None, 1, "a" * 65):
                with self.subTest(field=field, value=value), self.assertRaises(power.PowerError):
                    self.validate([dict(region(), **{field: value})])
        for location in ("south-centralus", "a" * 33):
            with self.assertRaises(power.PowerError):
                self.validate([dict(region(), location=location)])
        with self.assertRaisesRegex(power.PowerError, "reserved"):
            self.validate([dict(region(), env="all")])

    def test_project_name_and_derived_lengths_validated(self):
        for project in ("", "PLAZ", "../plaz", "a b", "a" * 63):
            with self.subTest(project=project), self.assertRaises(power.PowerError):
                self.validate([region()], project=project)
        target = power.resolve_target(self.validate([region()], project="lab-2"), "plaz", "lab-2")
        self.assertEqual(target["resource_group"], "rg-lab-2-compute-southcentralus")
        self.assertEqual(target["vm_name"], "vm-lab-2-gw1-scus-southcentralus")

    def test_required_fields_unknown_fields_and_boolean_types(self):
        for field in ("env", "location", "gateway", "regionCode", "enabled"):
            data = region()
            del data[field]
            with self.subTest(field=field), self.assertRaises(power.PowerError):
                self.validate([data])
        for field in ("enabled", "primary"):
            for value in (None, "true", "false", 0, 1, [], {}):
                with self.subTest(field=field, value=value), self.assertRaisesRegex(power.PowerError, "booleans"):
                    self.validate([dict(region(), **{field: value})])
        with self.assertRaises(power.PowerError):
            self.validate([dict(region(), enable=True)])
        with self.assertRaises(power.PowerError):
            self.validate([None])

    def test_duplicate_environment_location_gateway_include_disabled(self):
        for field in ("env", "location", "gateway"):
            duplicate = dict(secondary(), enabled=False, **{field: region()[field]})
            with self.subTest(field=field), self.assertRaisesRegex(power.PowerError, f"duplicate {field}"):
                self.validate([region(), duplicate])

    def test_exactly_one_enabled_primary(self):
        for entries in ([], [dict(region(), primary=False)], [dict(region(), enabled=False)],
                        [dict(region(), enabled=False), secondary()],
                        [region(), dict(secondary(), primary=True)]):
            with self.subTest(entries=entries), self.assertRaisesRegex(power.PowerError, "exactly one"):
                self.validate(entries)
        data = secondary()
        del data["primary"]
        self.assertEqual(len(self.validate([region(), data])), 2)

    def test_malformed_top_level_duplicate_keys_and_file_errors(self):
        for raw in ("not json", "[]", '{"regions": {}}', '{"regions": [], "regions": []}',
                    '{"regions": [], "extra": 1}', '{"regions": [], "_comment": null}',
                    '{"regions": [NaN]}', '{"regions": [{"env": "plaz", "env": "other"}]}'):
            with self.subTest(raw=raw), patch.object(Path, "read_text", return_value=raw), \
                    self.assertRaises(power.PowerError):
                power.validate_registry("fixture.json")
        for error in (FileNotFoundError, PermissionError, UnicodeError):
            with patch.object(Path, "read_text", side_effect=error), self.assertRaises(power.PowerError):
                power.validate_registry("fixture.json")

    def test_comment_formats_allowed(self):
        for comment in ("registry", ["registry", "text"]):
            with patch.object(Path, "read_text", return_value=json.dumps({"_comment": comment, "regions": [region()]})), \
                    patch.object(Path, "is_file", return_value=True):
                self.assertEqual(len(power.validate_registry("fixture.json")), 1)

    def test_targets_are_single_enabled_current_members(self):
        entries = [region(), dict(secondary(), enabled=False)]
        for environment, code in (("unknown", "UNKNOWN_TARGET"), ("plaz-sea", "DISABLED_TARGET"),
                                  ("all", "INVALID_TARGET"), ("../plaz", "INVALID_REGISTRY")):
            with self.subTest(environment=environment), self.assertRaises(power.PowerError) as caught:
                power.resolve_target(entries, environment)
            self.assertEqual(caught.exception.code, code)
        target = power.resolve_target(entries, "plaz")
        self.assertEqual(target["resource_group"], "rg-plaz-compute-southcentralus")
        self.assertEqual(target["vm_name"], "vm-plaz-gw1-scus-southcentralus")


class AzureTests(unittest.TestCase):
    def setUp(self):
        self.target = power.resolve_target([region()], "plaz")
        self.popen = patch.object(power.subprocess, "Popen").start()
        self.addCleanup(patch.stopall)
        self.processes = []

    def replies(self, *results):
        for result in results:
            process = MagicMock()
            process.__enter__.return_value = process
            process.communicate.return_value = (result.stdout, result.stderr)
            process.returncode = result.returncode
            self.processes.append(process)
        self.popen.side_effect = self.processes

    def commands(self):
        return [call.args[0] for call in self.popen.call_args_list]

    def assert_error(self, code, action="status"):
        with self.assertRaises(power.PowerError) as caught:
            power.operate(self.target, action)
        self.assertEqual(caught.exception.code, code)

    def test_stable_statuses_are_read_only_and_bounded(self):
        self.replies(*(response(statuses(state)) for state in ("running", "stopped", "deallocated")))
        for state in ("running", "stopped", "deallocated"):
            self.assertEqual(power.operate(self.target, "status")["power_state"], state)
        for command, call, process in zip(self.commands(), self.popen.call_args_list, self.processes):
            self.assertEqual(command, [
                "az", "vm", "get-instance-view", "--resource-group", self.target["resource_group"],
                "--name", self.target["vm_name"], "--query", "instanceView.statuses",
                "--output", "json", "--only-show-errors",
            ])
            self.assertTrue(call.kwargs["start_new_session"])
            self.assertNotIn("shell", call.kwargs)
            process.communicate.assert_called_once_with(timeout=power.READ_TIMEOUT)

    def test_real_azure_cli_shape_projects_nested_instance_view(self):
        # Live Azure CLI get-instance-view returns a VM object, not a bare
        # instance view. Querying root "statuses" succeeds but prints nothing.
        vm_response = {
            "name": self.target["vm_name"],
            "instanceView": {"statuses": json.loads(statuses("deallocated"))},
        }

        def azure_cli(command, **_):
            value = vm_response
            for field in command[command.index("--query") + 1].split("."):
                value = value.get(field) if isinstance(value, dict) else None
            process = MagicMock()
            process.__enter__.return_value = process
            process.returncode = 0
            process.communicate.return_value = (json.dumps(value) if value is not None else "", "")
            return process

        self.popen.side_effect = azure_cli
        result = power.operate(self.target, "status", SUBSCRIPTION)
        self.assertEqual(result["power_state"], "deallocated")
        self.assertEqual(result["outcome"], "observed")
        self.assertEqual(len(self.commands()), 1)
        self.assertEqual(self.commands()[0][-2:], ["--subscription", SUBSCRIPTION])

    def test_only_explicit_resource_absence_is_missing(self):
        self.replies(*(response(stderr=f"ERROR: ({code}) absent", returncode=3)
                       for code in ("ResourceNotFound", "ResourceGroupNotFound")))
        for _ in range(2):
            self.assertEqual(power.operate(self.target, "status")["power_state"], "missing")

    def test_error_codes_and_network_failures_never_become_missing(self):
        cases = [
            ("ERROR: (AuthorizationFailed) secret-auth-data", "AZURE_AUTH_ERROR"),
            ("ERROR: (InvalidAuthenticationToken) secret-auth-data", "AZURE_AUTH_ERROR"),
            ("ERROR: Please run 'az login' to setup account.", "AZURE_AUTH_ERROR"),
            ("ERROR: ConnectionError secret-auth-data", "AZURE_NETWORK_ERROR"),
            ("ERROR: (NotFound) ambiguous 404", "AZURE_COMMAND_ERROR"),
            ("ERROR: ResourceNotFound in error details", "AZURE_COMMAND_ERROR"),
            ("ERROR: (ResourceNotFound) absent\nERROR: (AuthorizationFailed) denied", "AZURE_AUTH_ERROR"),
            ("ERROR: (ResourceNotFound) absent\nConnectionError", "AZURE_NETWORK_ERROR"),
            ("ERROR: (ResourceNotFound) absent\nERROR: (OtherError) failed", "AZURE_COMMAND_ERROR"),
            ("ERROR: 403 Forbidden", "AZURE_AUTH_ERROR"),
            ("ERROR: (SubscriptionNotFound) absent", "AZURE_COMMAND_ERROR"),
        ]
        self.replies(*(response(stderr=stderr, returncode=1) for stderr, _ in cases))
        for stderr, code in cases:
            with self.subTest(stderr=stderr):
                self.assert_error(code)

    def test_malformed_ambiguous_and_unknown_instance_views_fail_closed(self):
        cases = [
            ("", "INVALID_RESPONSE"), ("null", "INVALID_RESPONSE"), ("{}", "INVALID_RESPONSE"),
            ("[]", "INVALID_RESPONSE"), ("not-json", "INVALID_RESPONSE"),
            ('[{"code": "PowerState/running", "code": "PowerState/stopped"}]', "INVALID_RESPONSE"),
            ('[{"code": "PowerState/running"}]', "INVALID_RESPONSE"),
            ('[{"code": "PowerState/running"}, null]', "INVALID_RESPONSE"),
            ('[{"code": 1}]', "INVALID_RESPONSE"),
            (json.dumps(json.loads(statuses()) + [{"code": "PowerState/running"}]), "AMBIGUOUS_STATE"),
            (json.dumps(json.loads(statuses()) + [{"code": "ProvisioningState/succeeded"}]), "AMBIGUOUS_STATE"),
            (statuses("unknown"), "INVALID_STATE"),
            (statuses(provisioning="failed"), "INVALID_STATE"),
        ]
        self.replies(*(response(raw) for raw, _ in cases))
        for raw, code in cases:
            with self.subTest(raw=raw):
                self.assert_error(code)

    def test_transitional_states_reject_status_and_mutations(self):
        cases = [(state, "succeeded") for state in ("starting", "stopping", "deallocating", "restarting")]
        cases += [("running", state) for state in ("updating", "creating", "deleting")]
        self.replies(*(response(statuses(state, provisioning)) for state, provisioning in cases for _ in range(3)))
        for state, provisioning in cases:
            for action in ("status", "start", "deallocate"):
                with self.subTest(state=state, provisioning=provisioning, action=action):
                    self.assert_error("TRANSITIONAL_STATE", action)
        self.assertTrue(all(command[2] == "get-instance-view" for command in self.commands()))

    def test_start_deallocate_exact_commands_and_final_confirmation(self):
        cases = [("start", "deallocated", "running"), ("start", "stopped", "running"),
                 ("deallocate", "running", "deallocated"), ("deallocate", "stopped", "deallocated")]
        self.replies(*(reply for _, initial, desired in cases
                       for reply in (response(statuses(initial)), response(), response(statuses(desired)))))
        for index, (action, initial, desired) in enumerate(cases):
            with self.subTest(action=action, initial=initial):
                result = power.operate(self.target, action, SUBSCRIPTION)
                self.assertEqual(result["initial_state"], initial)
                self.assertEqual(result["power_state"], desired)
                self.assertTrue(result["changed"])
                self.assertEqual(result["outcome"], "changed")
                commands = self.commands()[index * 3:index * 3 + 3]
                self.assertEqual(commands[1], [
                    "az", "vm", action, "--resource-group", self.target["resource_group"],
                    "--name", self.target["vm_name"], "--output", "none", "--only-show-errors",
                    "--subscription", SUBSCRIPTION,
                ])
                self.assertEqual(commands[0], commands[2])
                self.processes[index * 3 + 1].communicate.assert_called_once_with(timeout=power.MUTATION_TIMEOUT)
        for command in self.commands():
            self.assertEqual(command[-2:], ["--subscription", SUBSCRIPTION])
            self.assertNotIn("--no-wait", command)
            self.assertNotIn("account", command)

    def test_idempotence_does_not_mutate(self):
        self.replies(response(statuses("running")), response(statuses("deallocated")))
        for action in ("start", "deallocate"):
            result = power.operate(self.target, action)
            self.assertEqual(result["outcome"], "unchanged")
            self.assertFalse(result["changed"])
        self.assertTrue(all(command[2] == "get-instance-view" for command in self.commands()))

    def test_missing_gateway_is_never_created_or_mutated(self):
        self.replies(*(response(stderr="ERROR: (ResourceNotFound) absent", returncode=3) for _ in range(2)))
        for action in ("start", "deallocate"):
            self.assert_error("MISSING_TARGET", action)
        self.assertEqual(len(self.commands()), 2)
        self.assertTrue(all(command[2] == "get-instance-view" for command in self.commands()))

    def test_unsupported_actions_never_call_azure(self):
        self.assert_error("INVALID_ACTION", "delete")
        self.popen.assert_not_called()

    def test_mutation_failure_never_reports_success(self):
        self.replies(response(statuses()), response(stderr="ERROR: (AuthorizationFailed) denied", returncode=1))
        self.assert_error("AZURE_AUTH_ERROR", "deallocate")
        self.assertEqual(len(self.commands()), 2)

    def test_mutation_not_found_is_failure_not_a_missing_success(self):
        self.replies(response(statuses()), response(stderr="ERROR: (ResourceNotFound) absent", returncode=3))
        self.assert_error("AZURE_COMMAND_ERROR", "deallocate")

    def test_confirmation_must_equal_requested_state(self):
        self.replies(response(statuses()), response(), response(statuses("stopped")))
        self.assert_error("CONFIRMATION_FAILED", "deallocate")

    def test_missing_after_mutation_fails_confirmation(self):
        self.replies(response(statuses()), response(), response(stderr="ERROR: (ResourceNotFound) absent", returncode=3))
        self.assert_error("CONFIRMATION_FAILED", "deallocate")

    def test_transitional_or_malformed_confirmation_is_failure(self):
        self.replies(response(statuses()), response(), response(statuses("deallocating")),
                     response(statuses()), response(), response("invalid-json"))
        for code in ("TRANSITIONAL_STATE", "INVALID_RESPONSE"):
            self.assert_error(code, "deallocate")

    def test_timeout_kills_only_its_own_process_group(self):
        self.replies(response())
        process = self.processes[0]
        process.pid = 12345
        process.communicate.side_effect = [subprocess.TimeoutExpired(["az"], 120), ("", "")]
        with patch.object(power.os, "killpg") as killpg:
            self.assert_error("AZURE_TIMEOUT")
            killpg.assert_called_once_with(12345, signal.SIGKILL)
        self.assertEqual(process.communicate.call_args_list[-1].kwargs, {"timeout": 5})

    def test_missing_azure_binary_is_clear_failure(self):
        self.popen.side_effect = FileNotFoundError
        self.assert_error("AZURE_EXECUTION_ERROR")


class CliTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def invoke(self, argv, *, azure=None, entries=None, **environment):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, environment), \
                patch.object(Path, "read_text", return_value=json.dumps({"regions": entries or [region()]})), \
                patch.object(Path, "is_file", return_value=True), \
                patch.object(power, "run_azure", return_value=azure) as run, \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = power.main(argv)
        return result, stdout.getvalue(), stderr.getvalue(), run

    def test_validate_registry_uses_no_credentials_or_azure(self):
        result, stdout, stderr, run = self.invoke(["--validate-registry", "--registry", "custom.json"])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(stdout), {"status": "valid", "regions": 1, "enabled_regions": 1})
        self.assertEqual(stderr, "")
        run.assert_not_called()

    def test_resolve_target_outputs_exact_identity_without_azure(self):
        with patch("builtins.open", mock_open()) as output:
            result, stdout, _, run = self.invoke(["--environment", "plaz", "--resolve-target"],
                                                GITHUB_OUTPUT="actions-output")
        target = json.loads(stdout)
        self.assertEqual(result, 0)
        self.assertEqual(target, power.resolve_target([region()], "plaz"))
        self.assertIn("location=southcentralus\n", "".join(call.args[0] for call in output().write.call_args_list))
        self.assertIn(f"target={json.dumps(target, sort_keys=True)}\n",
                      "".join(call.args[0] for call in output().write.call_args_list))
        run.assert_not_called()

    def test_status_writes_one_json_and_power_output(self):
        for state in ("stopped", "deallocated", "running", "missing"):
            azure = response(statuses(state)) if state != "missing" else response(
                stderr="ERROR: (ResourceGroupNotFound) absent", returncode=3)
            with self.subTest(state=state), patch("builtins.open", mock_open()) as output:
                result, stdout, stderr, _ = self.invoke(["--environment", "plaz", "--action", "status"],
                                                       azure=azure, GITHUB_OUTPUT="actions-output")
                self.assertEqual(result, 0)
                self.assertEqual(len(stdout.splitlines()), 1)
                self.assertEqual(json.loads(stdout)["power_state"], state)
                self.assertEqual(stderr, "")
                output.assert_called_once_with("actions-output", "a", encoding="utf-8")
                self.assertIn(f"power_state={state}\n", "".join(call.args[0] for call in output().write.call_args_list))

    def test_failures_emit_no_success_json_outputs_or_auth_data(self):
        with patch("builtins.open", mock_open()) as output:
            result, stdout, stderr, _ = self.invoke(["--environment", "plaz", "--action", "status"],
                azure=response(stderr="ERROR: (AuthorizationFailed) secret-auth-data", returncode=1),
                GITHUB_OUTPUT="actions-output")
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(json.loads(stderr)["error"], "AZURE_AUTH_ERROR")
        self.assertNotIn("secret-auth-data", stderr)
        output.assert_not_called()

    def test_invalid_target_prevents_any_azure_call(self):
        for environment in ("unknown", "all", "plaz-sea"):
            with self.subTest(environment=environment):
                result, stdout, _, run = self.invoke(["--environment", environment, "--action", "start"],
                    entries=[region(), dict(secondary(), enabled=False)])
                self.assertEqual(result, 1)
                self.assertEqual(stdout, "")
                run.assert_not_called()

    def test_removed_target_prevents_a_queued_power_request(self):
        result, _, stderr, run = self.invoke(["--environment", "plaz-sea", "--action", "start"],
                                            entries=[region()])
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(stderr)["error"], "UNKNOWN_TARGET")
        run.assert_not_called()

    def test_subscription_and_project_override(self):
        result, stdout, _, run = self.invoke(
            ["--environment", "plaz", "--action", "status", "--subscription", SUBSCRIPTION],
            azure=response(statuses()), PROJECT_NAME="custom")
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(stdout)["vm_name"], "vm-custom-gw1-scus-southcentralus")
        self.assertEqual(run.call_args.args[0][-2:], ["--subscription", SUBSCRIPTION])

    def test_invalid_subscription_fails_before_azure(self):
        for subscription in ("", " ", " leading", "trailing ", "a\nb", "a\0b"):
            with self.subTest(subscription=subscription):
                result, _, stderr, run = self.invoke(
                    ["--environment", "plaz", "--action", "status", "--subscription", subscription])
                self.assertEqual(result, 1)
                self.assertEqual(json.loads(stderr)["error"], "INVALID_SUBSCRIPTION")
                run.assert_not_called()

    def test_cli_modes_and_required_fields(self):
        for argv in ([], ["--action", "start"], ["--environment", "plaz"],
                     ["--validate-registry", "--action", "start"],
                     ["--resolve-target", "--environment", "plaz", "--action", "start"],
                     ["--resolve-target", "--environment", "plaz", "--subscription", SUBSCRIPTION]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as caught:
                power.main(argv)
            self.assertEqual(caught.exception.code, 2)


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / ".github/workflows/gateway-power.yml").read_text()
        cls.script = (ROOT / ".github/scripts/gateway-power.py").read_text()

    def test_manual_only_single_target_and_safe_default(self):
        trigger = self.workflow.split("\non:\n", 1)[1].split("\npermissions:\n", 1)[0]
        self.assertIn("  workflow_dispatch:", trigger)
        for forbidden in ("push:", "pull_request:", "schedule:", "workflow_run:", "matrix:"):
            self.assertNotIn(forbidden, self.workflow)
        self.assertIn("type: string\n        default: plaz", trigger)
        self.assertIn("options: [status, start, deallocate]\n        default: status", trigger)
        self.assertNotIn("--environment all", self.workflow)

    def test_main_only_latest_source_and_read_only_resolve(self):
        self.assertEqual(self.workflow.count("if: github.ref == 'refs/heads/main'"), 2)
        self.assertEqual(self.workflow.count("ref: main"), 2)
        self.assertEqual(self.workflow.count("persist-credentials: false"), 2)
        resolve = self.workflow.split("\n  resolve:\n", 1)[1].split("\n  power:\n", 1)[0]
        self.assertIn("--resolve-target", resolve)
        self.assertNotIn("azure/login", resolve)
        self.assertNotIn("id-token: write", resolve)
        self.assertNotIn("secrets.", resolve)

    def test_shared_lifecycle_lock_oidc_approval_and_fresh_validation(self):
        job = self.workflow.split("\n  power:\n", 1)[1]
        self.assertIn("environment: production", job)
        self.assertIn("group: region-${{ needs.resolve.outputs.location }}", job)
        self.assertIn("cancel-in-progress: false", job)
        self.assertIn("id-token: write", job)
        self.assertIn("timeout-minutes: 25", job)
        self.assertLess(job.index("ref: main"), job.index("--resolve-target"))
        self.assertLess(job.index("--resolve-target"), job.index("azure/login@v2"))
        self.assertIn('if [ "$CURRENT_TARGET" != "$EXPECTED_TARGET" ]; then', job)
        self.assertIn("EXPECTED_TARGET: ${{ needs.resolve.outputs.target }}", job)
        self.assertIn("--subscription \"$AZURE_SUBSCRIPTION_ID\"", job)

    def test_inputs_are_env_bound_and_summary_does_not_claim_unverified_success(self):
        self.assertIn("TARGET_ENVIRONMENT: ${{ inputs.environment }}", self.workflow)
        self.assertIn("REQUESTED_ACTION: ${{ inputs.action }}", self.workflow)
        self.assertNotIn('--environment "${{', self.workflow)
        self.assertNotIn('--action "${{', self.workflow)
        self.assertIn("if: always()", self.workflow)
        self.assertIn("not established", self.workflow)
        for text in ("Requested action:", "Initial state:", "Verified result state:"):
            self.assertIn(text, self.workflow)

    def test_no_recreation_deletion_or_account_reconfiguration(self):
        for forbidden in ("az account set", "az vm create", "az vm delete", "az group delete",
                          "az deployment", "fa76accc-37a4-4b18-86a7-eb4d8b52c416"):
            self.assertNotIn(forbidden, self.workflow + self.script)


if __name__ == "__main__":
    unittest.main()

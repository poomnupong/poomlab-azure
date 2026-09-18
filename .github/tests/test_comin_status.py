"""Offline Comin protocol, classifier, and read-only runner regression tests."""

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest.mock import mock_open, patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
SPEC = importlib.util.spec_from_file_location("comin_status", SCRIPTS / "comin-status.py")
comin = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(comin)

NOW = 1789740000
FETCHED_AT = "2026-09-18T13:59:00Z"
OUT_PATH = "/nix/store/test-nixos-system-plaz-smoke"
SUBSCRIPTION = "fa76accc-37a4-4b18-86a7-eb4d8b52c416"


def healthy():
    return {
        "observed_at": NOW,
        "service": {"load": "loaded", "active": "active", "sub": "running", "result": "success"},
        "hostname": "plaz-smoke", "nixos_version": "25.11", "current_system": OUT_PATH,
        "generation_count": 1, "observation_error": "",
        "state": {
            "suspended": False, "fetching": False, "repository_error": False,
            "selected_commit": "abc123", "selected_remote": "origin",
            "signature_required": None, "signature_valid": None,
            "remote": {"name": "origin", "fetched_at": FETCHED_AT,
                       "fetched": True, "error": "none", "branch_error": False},
            "builder": {
                "evaluating": False, "building": False, "suspended": False,
                "generation": {"commit": "abc123", "eval_status": "evaluated",
                               "build_status": "built", "eval_error": False, "build_error": False},
            },
            "deployer": {
                "deploying": False, "suspended": False, "pending": False,
                "deployment": {"status": "done", "operation": "switch",
                               "ended_at": FETCHED_AT, "error": False,
                               "commit": "abc123", "out_path": OUT_PATH},
            },
        },
    }


def framed(observation):
    return f"COMIN_OBSERVATION_V1\n{json.dumps(observation)}\nCOMIN_OBSERVATION_END\n"


def response(stdout="", stderr="", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class ClassificationTests(unittest.TestCase):
    def classify(self, observation, **kwargs):
        return comin.classify(comin.parse_observation(framed(observation)), **kwargs)["status"]

    def test_running_healthy_requires_recent_fetch_and_activation(self):
        self.assertEqual(self.classify(healthy()), "HEALTHY")

    def test_inactive_and_failed_service_fail(self):
        for state in ("inactive", "failed"):
            with self.subTest(state=state):
                data = healthy()
                data["service"]["active"] = state
                data["state"] = None
                self.assertEqual(self.classify(data), "INACTIVE")

    def test_current_auth_error_is_not_hidden_by_existing_generation(self):
        data = healthy()
        data["state"]["remote"]["error"] = "authentication"
        self.assertEqual(self.classify(data), "AUTH_ERROR")

    def test_fetch_network_error_is_not_authentication_error(self):
        data = healthy()
        data["state"]["remote"]["error"] = "other"
        self.assertEqual(self.classify(data), "FETCH_ERROR")

    def test_old_recovered_journal_errors_do_not_override_live_status(self):
        data = healthy()
        data["journal"] = "Yesterday: Pull from remote 'origin' failed: authentication required"
        self.assertEqual(self.classify(data), "HEALTHY")
        self.assertNotIn("journalctl", (SCRIPTS / "comin-observe.sh").read_text())

    def test_stale_or_missing_fetch_evidence_is_unknown_not_healthy(self):
        for fetched_at in (None, "2026-09-18T13:00:00Z", "2026-09-18T15:00:00Z"):
            with self.subTest(fetched_at=fetched_at):
                data = healthy()
                data["state"]["remote"]["fetched_at"] = fetched_at
                self.assertEqual(self.classify(data), "UNKNOWN")

    def test_unavailable_status_is_unknown_not_healthy(self):
        data = healthy()
        data.update(state=None, observation_error="status_unavailable")
        self.assertEqual(self.classify(data), "UNKNOWN")

    def test_invalid_status_is_distinct_from_unavailable(self):
        data = healthy()
        data.update(state=None, observation_error="status_invalid")
        self.assertEqual(self.classify(data), "INVALID_OUTPUT")

    def test_current_build_eval_and_deploy_errors_fail(self):
        for component, key in (("generation", "eval_error"), ("generation", "build_error"),
                               ("deployment", "error")):
            with self.subTest(component=component, key=key):
                data = healthy()
                owner = "builder" if component == "generation" else "deployer"
                data["state"][owner][component][key] = True
                # Upstream marks failed deployment as "done"; error still wins.
                self.assertEqual(self.classify(data), "GITOPS_ERROR")

    def test_pending_new_commit_is_not_healthy(self):
        data = healthy()
        data["state"]["selected_commit"] = "def456"
        self.assertEqual(self.classify(data), "PENDING")

    def test_previous_success_during_in_progress_work_is_not_fresh_health(self):
        for component, key in ((None, "fetching"), ("builder", "evaluating"),
                               ("builder", "building"), ("deployer", "deploying"),
                               ("deployer", "pending")):
            with self.subTest(component=component, key=key):
                data = healthy()
                owner = data["state"][component] if component else data["state"]
                owner[key] = True
                self.assertEqual(self.classify(data), "PENDING")

    def test_unfinished_generation_is_not_masked_by_previous_deployment(self):
        for key, value in (("eval_status", "initialized"), ("eval_status", "evaluating"),
                           ("build_status", "initialized"), ("build_status", "building")):
            with self.subTest(key=key, value=value):
                data = healthy()
                data["state"]["builder"]["generation"][key] = value
                self.assertEqual(self.classify(data), "PENDING")

    def test_null_activity_fields_cannot_establish_fresh_health(self):
        data = healthy()
        data["state"]["fetching"] = None
        self.assertEqual(self.classify(data), "UNKNOWN")

    def test_new_service_with_no_fetch_or_deployment_is_unknown(self):
        data = healthy()
        data["generation_count"] = 0
        data["state"]["remote"].update(fetched_at=None, fetched=None)
        data["state"]["builder"]["generation"] = None
        data["state"]["deployer"]["deployment"] = None
        self.assertEqual(self.classify(data), "UNKNOWN")

    def test_generation_without_completed_activation_is_not_success(self):
        for change in ({"status": "running"}, {"out_path": "/nix/store/not-active"},
                       {"operation": "boot"}, {"ended_at": None}):
            with self.subTest(change=change):
                data = healthy()
                data["state"]["deployer"]["deployment"].update(change)
                self.assertEqual(self.classify(data), "PENDING")

    def test_smoke_requires_first_generation_and_exact_hostname(self):
        data = healthy()
        data["generation_count"] = 0
        self.assertEqual(self.classify(data, expected_hostname="plaz-smoke"), "PENDING")
        data = healthy()
        data["hostname"] = "plaz-smoke-wrong"
        self.assertEqual(self.classify(data, expected_hostname="plaz-smoke"), "ASSERTION_ERROR")

    def test_suspended_or_signature_failure_is_not_healthy(self):
        data = healthy()
        data["state"]["suspended"] = True
        self.assertEqual(self.classify(data), "GITOPS_ERROR")
        data = healthy()
        data["state"].update(signature_required=True, signature_valid=False)
        self.assertEqual(self.classify(data), "GITOPS_ERROR")

    def test_truncated_duplicate_or_invalid_output_is_rejected(self):
        for output in ("", "COMIN_OBSERVATION_END", framed(healthy()).splitlines()[1],
                       framed(healthy()) * 2, "COMIN_OBSERVATION_V1\nnot-json\nCOMIN_OBSERVATION_END"):
            with self.subTest(output=output[:60]), self.assertRaises(comin.InvalidObservation):
                comin.parse_observation(output)

    def test_missing_fields_types_and_bad_timestamps_are_rejected(self):
        variants = []
        data = healthy()
        del data["service"]["active"]
        variants.append(data)
        data = healthy()
        data["generation_count"] = "1"
        variants.append(data)
        data = healthy()
        data["state"]["remote"]["fetched_at"] = "yesterday"
        variants.append(data)
        data = healthy()
        data["state"] = None
        variants.append(data)
        for data in variants:
            with self.subTest(data=data), self.assertRaises(comin.InvalidObservation):
                comin.parse_observation(framed(data))


class ObservationTests(unittest.TestCase):
    def observe(self, replies, subscription=None):
        self.commands = []

        def runner(command, timeout):
            self.commands.append(command)
            self.assertGreater(timeout, 0)
            return replies[len(self.commands) - 1]

        return comin.observe("rg-test", "vm-test", 240, runner=runner, clock=lambda: 0,
                             subscription=subscription)

    def test_stopped_deallocated_and_absent_are_not_checked_without_run_command(self):
        replies = [
            response(json.dumps([f"PowerState/{state}"]))
            for state in ("stopped", "deallocated", "starting", "stopping", "deallocating")
        ] + [
            response(stderr=f"({code}) absent", returncode=3)
            for code in ("ResourceNotFound", "ResourceGroupNotFound")
        ]
        for reply in replies:
            with self.subTest(reply=reply):
                result = self.observe([reply])
                self.assertEqual(result["status"], "NOT_CHECKED")
                self.assertEqual(len(self.commands), 1)
                self.assertEqual(self.commands[0][1:3], ["vm", "get-instance-view"])

    def test_running_vm_uses_shared_azure_wrapper_and_protocol(self):
        data = self.observe([response('["PowerState/running"]'), response(framed(healthy()))])
        self.assertEqual(comin.classify(data)["status"], "HEALTHY")
        self.assertEqual(self.commands[1][0], "bash")
        self.assertEqual(Path(self.commands[1][1]).name, "az-run-command.sh")
        self.assertTrue(all("--subscription" not in command for command in self.commands))

    def test_explicit_subscription_reaches_both_commands_without_changing_account(self):
        data = self.observe(
            [response('["PowerState/running"]'), response(framed(healthy()))],
            subscription=SUBSCRIPTION,
        )
        self.assertEqual(comin.classify(data)["status"], "HEALTHY")
        self.assertEqual(len(self.commands), 2)
        self.assertEqual(self.commands[0][-2:], ["--subscription", SUBSCRIPTION])
        self.assertEqual(self.commands[1][4], (SCRIPTS / "comin-observe.sh").read_text())
        self.assertEqual(self.commands[1][5:], ["--subscription", SUBSCRIPTION])
        self.assertFalse(any("account" in command for command in self.commands))

    def test_deallocated_vm_subscription_is_forwarded_without_remote_command(self):
        result = self.observe([response('["PowerState/deallocated"]')], subscription=SUBSCRIPTION)
        self.assertEqual(result["status"], "NOT_CHECKED")
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(self.commands[0][-2:], ["--subscription", SUBSCRIPTION])

    def test_azure_permission_error_is_not_absent(self):
        result = self.observe([response(stderr="(AuthorizationFailed) denied", returncode=1)])
        self.assertEqual(result["status"], "TRANSPORT_ERROR")

    def test_transport_error_and_malformed_remote_output_are_distinct(self):
        for output, expected in (
            (response(stderr="run-command failed", returncode=1), "TRANSPORT_ERROR"),
            (response(stdout=""), "INVALID_OUTPUT"),
            (response(stdout="STATUS_CHECK_COMPLETE"), "INVALID_OUTPUT"),
        ):
            with self.subTest(expected=expected):
                result = self.observe([response('["PowerState/running"]'), output])
                self.assertEqual(result["status"], expected)

    def test_ambiguous_invalid_or_unknown_power_state_is_not_skipped(self):
        for stdout in ("null", "[]", "not-json", '["PowerState/unknown"]',
                       '["PowerState/running", "PowerState/stopped"]'):
            with self.subTest(stdout=stdout):
                self.assertEqual(self.observe([response(stdout)])["status"], "INVALID_OUTPUT")

    def test_azure_request_timeout_is_transport_error(self):
        def runner(command, timeout):
            raise subprocess.TimeoutExpired(command, timeout)

        result = comin.observe("rg", "vm", 500, runner=runner, clock=lambda: 0)
        self.assertEqual(result["status"], "TRANSPORT_ERROR")

    def test_runner_timeout_kills_process_group(self):
        process = unittest.mock.MagicMock()
        process.__enter__.return_value = process
        process.pid = 12345
        process.communicate.side_effect = [subprocess.TimeoutExpired(["bash"], 1), ("", "")]
        with patch.object(comin.subprocess, "Popen", return_value=process), \
                patch.object(comin.os, "killpg") as killpg, \
                self.assertRaises(subprocess.TimeoutExpired):
            comin.run(["bash"], 1)
        killpg.assert_called_once_with(12345, comin.signal.SIGKILL)


class WaitTests(unittest.TestCase):
    def test_monitor_forwards_subscription_to_each_observation(self):
        elapsed = [0]
        observer = unittest.mock.Mock(side_effect=[comin.report("PENDING", "starting"), healthy()])
        result = comin.monitor(
            "rg", "vm", wait=True, subscription=SUBSCRIPTION, observer=observer,
            clock=lambda: elapsed[0], sleep=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds),
            emit=lambda _: None,
        )
        self.assertEqual(result["status"], "HEALTHY")
        self.assertEqual(observer.call_count, 2)
        for call in observer.call_args_list:
            self.assertEqual(call.kwargs["subscription"], SUBSCRIPTION)

    def test_cli_forwards_explicit_subscription(self):
        with patch.object(sys, "argv", ["comin-status.py", "--subscription", SUBSCRIPTION]), \
                patch.dict(os.environ, {"SMOKE_RG": "rg", "VM_NAME": "vm"}, clear=True), \
                patch.object(comin, "monitor", return_value=comin.report("NOT_CHECKED", "VM stopped")) as monitor:
            self.assertEqual(comin.main(), 0)
        self.assertEqual(monitor.call_args.kwargs["subscription"], SUBSCRIPTION)

    def test_cli_rejects_empty_subscription_before_any_azure_call(self):
        with patch.object(sys, "argv", ["comin-status.py", "--subscription", " "]), \
                patch.dict(os.environ, {"SMOKE_RG": "rg", "VM_NAME": "vm"}, clear=True), \
                patch.object(comin, "monitor") as monitor, patch("sys.stderr"), \
                self.assertRaises(SystemExit) as raised:
            comin.main()
        self.assertEqual(raised.exception.code, 2)
        monitor.assert_not_called()

    def test_permanent_auth_error_aborts_first_round(self):
        data = healthy()
        data["state"]["remote"]["error"] = "authentication"
        with patch.object(comin.time, "sleep") as sleep:
            result = comin.monitor("rg", "vm", wait=True, observer=lambda *args, **kwargs: data,
                                   sleep=sleep, emit=lambda _: None)
        self.assertEqual(result["status"], "AUTH_ERROR")
        self.assertEqual(result["attempt"], 1)
        sleep.assert_not_called()

    def test_elapsed_time_includes_azure_calls_and_no_extra_sleep(self):
        elapsed = [0]
        calls = []
        sleeps = []

        def observe(*args, **kwargs):
            calls.append(args)
            elapsed[0] += 40
            return comin.report("UNKNOWN", "not ready")

        def sleep(seconds):
            sleeps.append(seconds)
            elapsed[0] += seconds

        result = comin.monitor("rg", "vm", wait=True, timeout=100, interval=30,
                               observer=observe, clock=lambda: elapsed[0], sleep=sleep,
                               emit=lambda _: None)
        self.assertEqual(result["status"], "TIMEOUT")
        self.assertEqual(result["elapsed_seconds"], 110)
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [30])
        self.assertTrue(all(args[2] == 100 for args in calls))

    def test_sleep_is_capped_at_remaining_wall_clock_budget(self):
        elapsed = [0]

        def sleep(seconds):
            self.assertEqual(seconds, 5)
            elapsed[0] += seconds

        result = comin.monitor(
            "rg", "vm", wait=True, timeout=5, interval=30,
            observer=lambda *args, **kwargs: comin.report("UNKNOWN", "not ready"),
            clock=lambda: elapsed[0], sleep=sleep, emit=lambda _: None,
        )
        self.assertEqual(result["status"], "TIMEOUT")
        self.assertEqual(result["elapsed_seconds"], 5)

    def test_smoke_not_checked_is_failure_but_fleet_skip_is_nonfailure(self):
        for wait, expected in ((False, 0), (True, 1)):
            with self.subTest(wait=wait), \
                    patch.object(sys, "argv", ["comin-status.py"] + (["--wait"] if wait else [])), \
                    patch.dict(os.environ, {"SMOKE_RG": "rg", "VM_NAME": "vm"}, clear=True), \
                    patch.object(comin, "monitor", return_value=comin.report("NOT_CHECKED", "VM stopped")), \
                    patch("builtins.print"):
                self.assertEqual(comin.main(), expected)

    def test_only_successful_smoke_writes_deployed_environment(self):
        for status in ("HEALTHY", "AUTH_ERROR", "TIMEOUT", "NOT_CHECKED"):
            with self.subTest(status=status):
                opened = mock_open()
                with patch.object(sys, "argv", ["comin-status.py", "--wait"]), \
                        patch.dict(os.environ, {"SMOKE_RG": "rg", "VM_NAME": "vm",
                                                "GITHUB_ENV": "github-env"}, clear=True), \
                        patch.object(comin, "monitor", return_value=comin.report(status, "test")), \
                        patch("builtins.open", opened), patch("builtins.print"):
                    code = comin.main()
                self.assertEqual(code, 0 if status == "HEALTHY" else 1)
                if status == "HEALTHY":
                    opened().write.assert_called_once_with("COMIN_DEPLOYED=true\n")
                else:
                    opened.assert_not_called()


class RemoteProjectionTests(unittest.TestCase):
    """Exercise the actual remote jq projection with upstream-shaped JSON."""

    def project(self, raw):
        source = (SCRIPTS / "comin-observe.sh").read_text()
        projection = re.search(r"jq -ce '(.+?)' 2>/dev/null", source, re.DOTALL).group(1)
        return subprocess.run(["jq", "-ce", projection], input=json.dumps(raw),
                              text=True, capture_output=True, check=False)

    def upstream_state(self):
        data = healthy()["state"]
        return {
            "is_suspended": False,
            "fetcher": {"is_fetching": False, "repository_status": {
                "error_msg": "", "selected_commit_id": "abc123", "selected_remote_name": "origin",
                "selected_commit_should_be_signed": None, "selected_commit_signed": None,
                "remotes": [{"name": "origin", "fetch_error_msg": "", "fetched": True,
                             "fetched_at": FETCHED_AT, "main": {"error_msg": ""}}],
            }},
            "builder": {
                "is_evaluating": False, "is_building": False, "is_suspended": False,
                "generation": {"selected_commit_id": "abc123", "eval_status": "evaluated",
                               "build_status": "built", "eval_err": "", "build_err": ""},
            },
            "deployer": {
                "is_deploying": False, "is_suspended": False, "generation_to_deploy": None,
                "deployment": {
                    "status": "done", "operation": "switch", "ended_at": FETCHED_AT,
                    "error_msg": "", "generation": {
                        "selected_commit_id": data["deployer"]["deployment"]["commit"],
                        "out_path": OUT_PATH,
                    },
                },
            },
            # Never send persisted journal/error history, URLs, or commit messages.
            "store": {"deployments": [{"error_msg": "old authentication required"}]},
        }

    def test_upstream_json_projects_to_valid_small_healthy_observation(self):
        output = self.project(self.upstream_state())
        self.assertEqual(output.returncode, 0, output.stderr)
        data = healthy()
        data["state"] = json.loads(output.stdout)
        self.assertLess(len(framed(data)), 3500)
        self.assertEqual(comin.classify(comin.parse_observation(framed(data)))["status"], "HEALTHY")
        self.assertNotIn("old authentication", output.stdout)

    def test_authentication_error_category_and_recovery_follow_current_field(self):
        raw = self.upstream_state()
        remote = raw["fetcher"]["repository_status"]["remotes"][0]
        remote["fetch_error_msg"] = "'git fetch origin' fails: 'authentication required'"
        output = self.project(raw)
        self.assertEqual(json.loads(output.stdout)["remote"]["error"], "authentication")
        self.assertNotIn("git fetch", output.stdout)
        remote["fetch_error_msg"] = ""
        self.assertEqual(json.loads(self.project(raw).stdout)["remote"]["error"], "none")

    def test_upstream_null_error_fields_are_rejected_not_defaulted_to_success(self):
        raw = self.upstream_state()
        raw["fetcher"]["repository_status"]["remotes"][0]["fetch_error_msg"] = None
        self.assertNotEqual(self.project(raw).returncode, 0)


if __name__ == "__main__":
    unittest.main()

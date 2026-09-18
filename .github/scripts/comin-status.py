#!/usr/bin/env python3
"""Read-only fleet checks and deadline-bounded first-deployment smoke checks.

Fleet: python3 .github/scripts/comin-status.py --resource-group RG --vm-name VM
Smoke: SMOKE_RG=RG VM_NAME=VM python3 .github/scripts/comin-status.py --wait
Add --subscription ID_OR_NAME to scope both Azure calls without changing the
Azure CLI account default. If omitted, the existing CLI subscription is used.

Writes one JSON report per observation and a final Actions summary. Exit 0 means
HEALTHY (or NOT_CHECKED in fleet mode only); every other final state exits 1.
Only a successful --wait appends COMIN_DEPLOYED=true to GITHUB_ENV. Its defaults
are a 1800s wall-clock deadline, 30s interval, 300s fetch freshness and hostname
plaz-smoke. Azure command time counts against the deadline. Never starts VMs.

The projection/classifier targets nlewo/comin 4f14d338d755239c27131cbf6b466be4bbb20f91:
  cmd/status.go, pkg/protobuf/services.proto, internal/repository/repository.go
  https://github.com/nlewo/comin/tree/4f14d338d755239c27131cbf6b466be4bbb20f91
fetched_at marks the latest *attempt*, not necessarily success. DeploymentFinished
in internal/store/deployment.go sets status=done even after an error: error_msg
must also be checked. No historical journal grep or cumulative metric is used.
"""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


SCRIPTS = Path(__file__).resolve().parent
NON_RUNNING = {"stopped", "deallocated", "stopping", "deallocating", "starting"}
RETRYABLE = {"UNKNOWN", "PENDING"}


class InvalidObservation(ValueError):
    pass


def fields(value, schema):
    if not isinstance(value, dict):
        raise InvalidObservation("expected an object")
    for key, types in schema.items():
        types = types if isinstance(types, tuple) else (types,)
        if key not in value or type(value[key]) not in types:
            raise InvalidObservation(f"missing or invalid {key}")


def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("missing timezone")
        return parsed.timestamp()
    except (ValueError, TypeError, AttributeError, OverflowError) as exc:
        raise InvalidObservation("invalid status timestamp") from exc


def parse_observation(stdout):
    lines = stdout.strip().splitlines()
    if len(lines) != 3 or lines[0] != "COMIN_OBSERVATION_V1" or lines[-1] != "COMIN_OBSERVATION_END":
        raise InvalidObservation("missing, duplicate, or truncated observation sentinel")
    try:
        observation = json.loads(lines[1])
    except (ValueError, TypeError) as exc:
        raise InvalidObservation("invalid observation JSON") from exc
    fields(observation, {
        "observed_at": int, "service": dict, "hostname": str, "nixos_version": str,
        "current_system": str, "generation_count": int, "observation_error": str,
        "state": (dict, type(None)),
    })
    fields(observation["service"], {key: str for key in ("load", "active", "sub", "result")})
    if observation["observed_at"] <= 0 or observation["generation_count"] < 0:
        raise InvalidObservation("invalid observation time or generation count")
    if observation["observation_error"] not in {"", "status_unavailable", "status_invalid"}:
        raise InvalidObservation("unrecognized observation error")
    state = observation["state"]
    if state is None:
        if observation["service"]["active"] == "active" and not observation["observation_error"]:
            raise InvalidObservation("active service has no status or collection error")
        return observation
    optional_bool = (bool, type(None))
    fields(state, {
        "suspended": optional_bool, "fetching": optional_bool, "repository_error": bool,
        "selected_commit": str, "selected_remote": str,
        "signature_required": optional_bool, "signature_valid": optional_bool,
        "remote": (dict, type(None)), "builder": dict, "deployer": dict,
    })
    remote = state["remote"]
    if remote is not None:
        fields(remote, {
            "name": str, "fetched_at": (str, type(None)), "fetched": optional_bool,
            "error": str, "branch_error": bool,
        })
        if remote["name"] != "origin" or remote["error"] not in {"none", "authentication", "other"}:
            raise InvalidObservation("unexpected remote or fetch error category")
        if remote["fetched_at"] is not None:
            timestamp(remote["fetched_at"])
    fields(state["builder"], {
        "evaluating": optional_bool, "building": optional_bool, "suspended": optional_bool,
        "generation": (dict, type(None)),
    })
    generation = state["builder"]["generation"]
    if generation is not None:
        fields(generation, {
            "commit": str, "eval_status": str, "build_status": str,
            "eval_error": bool, "build_error": bool,
        })
    fields(state["deployer"], {
        "deploying": optional_bool, "suspended": optional_bool, "pending": bool,
        "deployment": (dict, type(None)),
    })
    deployment = state["deployer"]["deployment"]
    if deployment is not None:
        fields(deployment, {
            "status": str, "operation": str, "ended_at": (str, type(None)), "error": bool,
            "commit": str, "out_path": str,
        })
        if deployment["ended_at"] is not None:
            timestamp(deployment["ended_at"])
    return observation


def report(status, reason, observation=None):
    result = {"status": status, "reason": reason}
    if observation:
        result.update({key: observation[key] for key in (
            "service", "hostname", "nixos_version", "generation_count",
        )})
        state = observation["state"]
        if state and state["remote"]:
            result["last_fetch_at"] = state["remote"]["fetched_at"]
            result["last_fetch_error"] = state["remote"]["error"]
        if state and state["deployer"]["deployment"]:
            result["deployment_status"] = state["deployer"]["deployment"]["status"]
    return result


def classify(observation, max_fetch_age=300, expected_hostname=None):
    def result(status, reason):
        return report(status, reason, observation)

    service = observation["service"]
    if service["load"] != "loaded" or service["active"] in {"inactive", "failed"}:
        return result("INACTIVE", "Comin is not active; systemd activity is not GitOps health")
    if service["active"] != "active":
        return result("PENDING", "Comin service is transitioning; GitOps is not yet verified")
    if observation["observation_error"] == "status_invalid":
        return result("INVALID_OUTPUT", "Comin status returned invalid or unsupported JSON")
    if observation["observation_error"]:
        return result("UNKNOWN", "Comin is active but its current status API is unavailable")
    state = observation["state"]
    remote = state["remote"]
    if remote is None or remote["fetched_at"] is None:
        return result("UNKNOWN", "No current origin fetch evidence; active is not healthy")
    age = observation["observed_at"] - timestamp(remote["fetched_at"])
    if age < -30 or age > max_fetch_age:
        return result("UNKNOWN", "Origin fetch evidence is stale or has an invalid future clock")
    if remote["error"] == "authentication":
        return result("AUTH_ERROR", "Latest origin fetch rejected authentication/authorization; check GitHub token access")
    if remote["error"] != "none":
        return result("FETCH_ERROR", "Latest origin fetch failed (not an authentication rejection)")
    if remote["fetched"] is not True:
        return result("UNKNOWN", "No successful origin fetch established")
    if remote["branch_error"] or state["repository_error"]:
        return result("GITOPS_ERROR", "Current repository/branch selection has an error")
    if state["signature_required"] is True and state["signature_valid"] is not True:
        return result("GITOPS_ERROR", "Selected commit does not satisfy Comin signature policy")
    builder, deployer = state["builder"], state["deployer"]
    if state["suspended"] or builder["suspended"] or deployer["suspended"]:
        return result("GITOPS_ERROR", "Comin reconciliation is suspended")
    generation, deployment = builder["generation"], deployer["deployment"]
    if generation and (generation["eval_status"] == "failed" or generation["eval_error"]
                       or generation["build_status"] == "failed" or generation["build_error"]):
        return result("GITOPS_ERROR", "Current generation evaluation/build failed")
    # The pinned implementation can report status=done AND error_msg != "".
    if deployment and (deployment["status"] == "failed" or deployment["error"]):
        return result("GITOPS_ERROR", "Latest deployment failed (including errors reported as done)")
    if (state["fetching"] or builder["evaluating"] or builder["building"]
            or deployer["deploying"] or deployer["pending"]):
        return result("PENDING", "Comin is fetching, evaluating, building, or deploying; not yet converged")
    if any(flag is None for flag in (
            state["fetching"], state["suspended"], builder["evaluating"],
            builder["building"], builder["suspended"], deployer["deploying"], deployer["suspended"])):
        return result("UNKNOWN", "Comin activity/suspension fields are unknown; convergence is not verified")
    if generation and (generation["eval_status"] in {"initialized", "evaluating"}
                       or generation["build_status"] in {"initialized", "building"}):
        return result("PENDING", "Current generation is not finished; previous deployment is not fresh convergence evidence")
    if not deployment or deployment["status"] != "done" or not deployment["ended_at"]:
        return result("PENDING", "No completed successful Comin deployment")
    if not state["selected_commit"] or state["selected_remote"] != "origin":
        return result("UNKNOWN", "No selected origin commit")
    if deployment["commit"] != state["selected_commit"]:
        return result("PENDING", "Latest fetched commit has not been successfully deployed")
    if (deployment["operation"] not in {"switch", "test"}
            or not deployment["out_path"]
            or deployment["out_path"] != observation["current_system"]):
        return result("PENDING", "Comin deployment is not the currently activated system")
    if observation["generation_count"] < 1:
        return result("PENDING", "No first Comin profile generation")
    if not observation["hostname"] or not observation["nixos_version"]:
        return result("INVALID_OUTPUT", "Hostname or NixOS version assertion is empty")
    if expected_hostname and observation["hostname"] != expected_hostname:
        return result("ASSERTION_ERROR", "Activated system does not have the expected smoke hostname")
    return result("HEALTHY", "Recent origin fetch succeeded and its successful deployment is active")


def run(command, timeout):
    # Kill the wrapper AND its Azure CLI child on timeout. Killing just the shell
    # can leave a child holding the output pipe and defeat the wall-clock bound.
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def observe(resource_group, vm_name, deadline, runner=run, clock=time.monotonic,
            subscription=None):
    subscription_args = ["--subscription", subscription] if subscription is not None else []

    def invoke(command):
        remaining = deadline - clock()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, 0)
        return runner(command, min(180, remaining))

    try:
        vm = invoke([
            "az", "vm", "get-instance-view", "--resource-group", resource_group,
            "--name", vm_name, "--query",
            "instanceView.statuses[?starts_with(code, 'PowerState/')].code", "--output", "json",
        ] + subscription_args)
        if vm.returncode:
            if re.search(r"\b(ResourceNotFound|ResourceGroupNotFound)\b", vm.stderr):
                return report("NOT_CHECKED", "VM or resource group is absent; no VM was started")
            return report("TRANSPORT_ERROR", f"Azure power-state query failed (exit {vm.returncode})")
        try:
            power_states = json.loads(vm.stdout)
        except ValueError:
            return report("INVALID_OUTPUT", "Azure power-state query did not return JSON")
        if not isinstance(power_states, list) or len(power_states) != 1 or not isinstance(power_states[0], str):
            return report("INVALID_OUTPUT", "Azure returned no unambiguous VM power state")
        power_state = power_states[0]
        if power_state != "PowerState/running":
            if power_state.removeprefix("PowerState/") in NON_RUNNING and power_state.startswith("PowerState/"):
                return report("NOT_CHECKED", f"VM is {power_state}; no VM was started")
            return report("INVALID_OUTPUT", "Azure returned an unknown VM power state")
        output = invoke([
            "bash", str(SCRIPTS / "az-run-command.sh"), resource_group, vm_name,
            (SCRIPTS / "comin-observe.sh").read_text(),
        ] + subscription_args)
        if output.returncode:
            return report("TRANSPORT_ERROR", f"Azure run-command failed (exit {output.returncode}); not a Comin health result")
        try:
            return parse_observation(output.stdout)
        except InvalidObservation as exc:
            return report("INVALID_OUTPUT", str(exc))
    except subprocess.TimeoutExpired:
        if clock() >= deadline:
            return report("TIMEOUT", "Wall-clock deadline expired during an Azure command")
        return report("TRANSPORT_ERROR", "Azure command exceeded its 180s request budget")
    except OSError:
        return report("TRANSPORT_ERROR", "Unable to execute the Azure observation tooling")


def monitor(resource_group, vm_name, *, wait=False, timeout=1800, interval=30,
            max_fetch_age=300, expected_hostname="plaz-smoke", subscription=None, observer=observe,
            clock=time.monotonic, sleep=time.sleep, emit=print):
    started = clock()
    deadline = started + timeout
    attempt = 0
    while clock() < deadline:
        attempt += 1
        observation = observer(resource_group, vm_name, deadline, subscription=subscription)
        result = observation if "status" in observation else classify(
            observation, max_fetch_age, expected_hostname if wait else None,
        )
        result.update(attempt=attempt, elapsed_seconds=round(clock() - started, 1))
        # A late successful remote response must not defeat the bounded deadline.
        if clock() >= deadline:
            result.update(status="TIMEOUT", reason="Wall-clock observation deadline exhausted")
        emit(json.dumps(result, sort_keys=True))
        if not wait or result["status"] not in RETRYABLE:
            return result
        remaining = deadline - clock()
        if remaining > 0:
            sleep(min(interval, remaining))
    result = report("TIMEOUT", "Comin did not converge within the wall-clock deadline")
    result.update(attempt=attempt, elapsed_seconds=round(clock() - started, 1))
    emit(json.dumps(result, sort_keys=True))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resource-group", default=os.environ.get("SMOKE_RG"))
    parser.add_argument("--vm-name", default=os.environ.get("VM_NAME"))
    parser.add_argument("--subscription", help="Azure subscription ID/name; does not change the CLI default")
    parser.add_argument("--wait", action="store_true")
    parser.add_argument("--timeout-seconds", type=int, default=1800)
    parser.add_argument("--interval-seconds", type=int, default=30)
    parser.add_argument("--max-fetch-age-seconds", type=int, default=300)
    parser.add_argument("--expected-hostname", default="plaz-smoke")
    args = parser.parse_args()
    if not args.resource_group or not args.vm_name:
        parser.error("--resource-group/SMOKE_RG and --vm-name/VM_NAME are required")
    if args.subscription is not None and not args.subscription.strip():
        parser.error("--subscription must not be empty")
    if min(args.timeout_seconds, args.interval_seconds, args.max_fetch_age_seconds) <= 0:
        parser.error("timeout, interval, and fetch age must be positive")
    result = monitor(
        args.resource_group, args.vm_name, wait=args.wait, timeout=args.timeout_seconds,
        interval=args.interval_seconds, max_fetch_age=args.max_fetch_age_seconds,
        expected_hostname=args.expected_hostname, subscription=args.subscription,
    )
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(f"### Comin: {result['status']}\n\n{result['reason']}\n\n")
            if "service" in result:
                summary.write(f"Systemd activity: `{result['service']['active']}`. "
                              f"Comin generations: `{result['generation_count']}`.\n\n")
            summary.write("Systemd activity alone is not authenticated GitOps health. "
                          "Stopped/missing VMs are NOT CHECKED and are never started.\n")
    success = result["status"] == "HEALTHY"
    if args.wait and success and os.environ.get("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a") as env:
            env.write("COMIN_DEPLOYED=true\n")
    if not success and not (not args.wait and result["status"] == "NOT_CHECKED"):
        print(f"::error::Comin {result['status']}: {result['reason']}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

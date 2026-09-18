#!/usr/bin/env python3
"""Validate region membership or control exactly one existing gateway's power.

Credential-free:
  python3 .github/scripts/gateway-power.py --validate-registry
  python3 .github/scripts/gateway-power.py --environment plaz --resolve-target
Azure (never creates/deletes resources or changes the CLI account default):
  python3 .github/scripts/gateway-power.py --environment plaz --action status
  python3 .github/scripts/gateway-power.py --environment plaz --action deallocate
  python3 .github/scripts/gateway-power.py --environment plaz --action start

--subscription ID_OR_NAME scopes every Azure call. PROJECT_NAME defaults to plaz.
--registry selects another JSON registry; required files still resolve relative
to this repository. Only enabled registry members may be power targets. Removing
or disabling membership is destructive deployment cleanup, not power control.

Success prints one JSON object and appends Actions outputs when GITHUB_OUTPUT is
set. status reports running/stopped/deallocated/missing; all other states fail
closed. Errors print sanitized JSON to stderr, never raw Azure diagnostics.
Azure reads take at most 120s and synchronous mutations at most 900s each.
A timed-out mutation may still finish in Azure: check status before retrying.
"""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
READ_TIMEOUT = 120
MUTATION_TIMEOUT = 900
NAME = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*", re.ASCII)
LOCATION = re.compile(r"[a-z][a-z0-9]{0,31}", re.ASCII)
STABLE_STATES = {"running", "stopped", "deallocated"}
TRANSITIONAL_STATES = {"starting", "stopping", "deallocating", "restarting", "creating"}
MISSING_CODES = {"ResourceNotFound", "ResourceGroupNotFound"}
AUTH_CODES = {
    "AuthorizationFailed", "AuthenticationFailed", "InvalidAuthenticationToken",
    "ExpiredAuthenticationToken", "InvalidAuthenticationTokenTenant",
    "AuthorizationPermissionMismatch", "Forbidden", "Unauthorized",
}


class PowerError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def invalid_constant(_):
    raise ValueError("invalid JSON constant")


def parse_json(text):
    return json.loads(text, object_pairs_hook=unique_object,
                      parse_constant=invalid_constant)


def safe_name(value, field, pattern=NAME):
    if not isinstance(value, str) or len(value) > 63 or not pattern.fullmatch(value):
        raise PowerError("INVALID_REGISTRY", f"{field} must be a safe lowercase name.")
    return value


def target_for(region, project_name):
    target = {
        "environment": region["env"],
        "location": region["location"],
        "gateway": region["gateway"],
        "project_name": project_name,
        "resource_group": f"rg-{project_name}-compute-{region['location']}",
        "vm_name": f"vm-{project_name}-{region['gateway']}-{region['location']}",
    }
    if len(target["resource_group"]) > 90 or len(target["vm_name"]) > 64:
        raise PowerError("INVALID_REGISTRY", "Derived resource names exceed Azure naming limits.")
    return target


def validate_registry(path, project_name="plaz"):
    safe_name(project_name, "PROJECT_NAME")
    try:
        registry = parse_json(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError, RecursionError) as exc:
        raise PowerError("INVALID_REGISTRY", "Registry must be readable, valid JSON without duplicate keys.") from exc
    if (not isinstance(registry, dict) or set(registry) - {"regions", "_comment"}
            or not isinstance(registry.get("regions"), list)):
        raise PowerError("INVALID_REGISTRY", "Registry must contain a regions array and optional _comment.")
    if "_comment" in registry and not (
            isinstance(registry["_comment"], str)
            or isinstance(registry["_comment"], list)
            and all(isinstance(line, str) for line in registry["_comment"])):
        raise PowerError("INVALID_REGISTRY", "Registry _comment must be text or an array of text.")
    regions = registry["regions"]
    required = {"env", "location", "gateway", "regionCode", "enabled"}
    seen = {key: set() for key in ("env", "location", "gateway")}
    for region in regions:
        if (not isinstance(region, dict) or required - set(region)
                or set(region) - (required | {"primary"})):
            raise PowerError("INVALID_REGISTRY", "Each region must use the supported registry fields.")
        for field in ("env", "gateway", "regionCode"):
            safe_name(region[field], field)
        safe_name(region["location"], "location", LOCATION)
        if region["env"] == "all":
            raise PowerError("INVALID_REGISTRY", "Environment 'all' is reserved; power control is single-region.")
        if type(region["enabled"]) is not bool or type(region.get("primary", False)) is not bool:
            raise PowerError("INVALID_REGISTRY", "enabled and primary must be JSON booleans.")
        for field, values in seen.items():
            if region[field] in values:
                raise PowerError("INVALID_REGISTRY", f"Registry contains a duplicate {field}.")
            values.add(region[field])
        target_for(region, project_name)
        if region["enabled"]:
            required_files = [
                ROOT / "infra" / "environments" / f"{region['env']}-{layer}.bicepparam"
                for layer in ("landing-zone", "workload")
            ] + [
                ROOT / "nixos" / "hosts" / region["gateway"] / filename
                for filename in ("default.nix", "hardware.nix")
            ]
            for filename in required_files:
                if not filename.is_file():
                    raise PowerError("INVALID_REGISTRY", f"Enabled region requires {filename.relative_to(ROOT)}.")
    if sum(region["enabled"] and region.get("primary", False) for region in regions) != 1:
        raise PowerError("INVALID_REGISTRY", "Registry must have exactly one enabled primary region.")
    return regions


def resolve_target(regions, environment, project_name="plaz"):
    safe_name(environment, "environment")
    if environment == "all":
        raise PowerError("INVALID_TARGET", "Environment 'all' is not a power-control target.")
    for region in regions:
        if region["env"] == environment:
            if not region["enabled"]:
                raise PowerError("DISABLED_TARGET", "Disabled regions cannot be power-control targets.")
            return target_for(region, project_name)
    raise PowerError("UNKNOWN_TARGET", "Environment is not present in the current registry.")


def run_azure(command, timeout):
    try:
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as exc:
                # Bound the whole CLI process tree, including inherited output pipes.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate(timeout=5)
                raise PowerError("AZURE_TIMEOUT", "Azure command timed out; query status before retrying.") from exc
            return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except PowerError:
        raise
    except subprocess.TimeoutExpired as exc:
        raise PowerError("AZURE_TIMEOUT", "Azure command did not terminate within its deadline.") from exc
    except (OSError, UnicodeError) as exc:
        raise PowerError("AZURE_EXECUTION_ERROR", "Unable to execute or read Azure CLI.") from exc


def azure_failure(stderr, allow_missing=False):
    # Only a single explicit top-level Azure not-found code establishes absence.
    # Text mentioning "not found", login failures and generic 404s never do.
    lines = [line.strip() for line in stderr.splitlines() if line.strip()]
    errors = [line for line in lines if line.startswith("ERROR:")]
    matches = [re.match(r"^ERROR:\s+\(([A-Za-z0-9]+)\)(?:\s|$)", line) for line in errors]
    codes = {match.group(1) for match in matches if match}
    if codes & AUTH_CODES or any(term in stderr.lower() for term in (
            "please run 'az login'", 'please run "az login"', "aadsts", "authentication required",
            "unauthorized", "forbidden", "authorizationfailed", "authenticationfailed")):
        raise PowerError("AZURE_AUTH_ERROR", "Azure rejected authentication or authorization.")
    if any(term in stderr.lower() for term in (
            "connectionerror", "connection error", "connection failed", "connection refused",
            "name resolution", "timed out", "max retries exceeded", "proxyerror", "sslerror")):
        raise PowerError("AZURE_NETWORK_ERROR", "Azure request failed due to a network error.")
    if allow_missing and len(errors) == 1 and codes & MISSING_CODES:
        return "missing"
    raise PowerError("AZURE_COMMAND_ERROR", "Azure command failed; no power state was established.")


def azure_command(target, operation, subscription):
    command = [
        "az", "vm", operation,
        "--resource-group", target["resource_group"], "--name", target["vm_name"],
    ]
    if operation == "get-instance-view":
        # Azure CLI wraps instance-view statuses inside its VM result.
        command += ["--query", "instanceView.statuses", "--output", "json"]
    else:
        command += ["--output", "none"]
    command += ["--only-show-errors"]
    if subscription is not None:
        command += ["--subscription", subscription]
    return command


def power_state(target, subscription=None):
    result = run_azure(azure_command(target, "get-instance-view", subscription), READ_TIMEOUT)
    if result.returncode:
        return azure_failure(result.stderr, allow_missing=True)
    try:
        statuses = parse_json(result.stdout)
    except (ValueError, RecursionError) as exc:
        raise PowerError("INVALID_RESPONSE", "Azure returned invalid instance-view JSON.") from exc
    if (not isinstance(statuses, list) or not statuses
            or any(not isinstance(item, dict) or not isinstance(item.get("code"), str)
                   or not re.fullmatch(r"[A-Za-z]+/[A-Za-z]+", item["code"]) for item in statuses)):
        raise PowerError("INVALID_RESPONSE", "Azure returned malformed instance-view statuses.")
    power = [item["code"].split("/", 1)[1] for item in statuses if item["code"].startswith("PowerState/")]
    provisioning = [
        item["code"].split("/", 1)[1] for item in statuses if item["code"].startswith("ProvisioningState/")
    ]
    if len(power) > 1 or len(provisioning) > 1:
        raise PowerError("AMBIGUOUS_STATE", "Azure returned multiple power or provisioning states.")
    if len(power) != 1 or len(provisioning) != 1:
        raise PowerError("INVALID_RESPONSE", "Azure did not return one power and one provisioning state.")
    if power[0] in TRANSITIONAL_STATES or provisioning[0] in {"creating", "updating", "deleting", "migrating"}:
        raise PowerError("TRANSITIONAL_STATE", "Gateway is transitioning; query status before retrying.")
    if provisioning[0] != "succeeded":
        raise PowerError("INVALID_STATE", "Gateway provisioning is not in the succeeded state.")
    if power[0] not in STABLE_STATES:
        raise PowerError("INVALID_STATE", "Azure returned an unsupported gateway power state.")
    return power[0]


def operate(target, action, subscription=None):
    if action not in {"status", "start", "deallocate"}:
        raise PowerError("INVALID_ACTION", "Only status, start, and deallocate are supported.")
    initial = power_state(target, subscription)
    desired = {"start": "running", "deallocate": "deallocated"}.get(action)
    result = {
        **target, "action": action, "initial_state": initial, "requested_state": desired,
        "power_state": initial, "changed": False, "outcome": "observed",
    }
    if action == "status":
        return result
    if initial == "missing":
        raise PowerError("MISSING_TARGET", "Gateway is missing; power control never recreates resources.")
    if initial == desired:
        result["outcome"] = "unchanged"
        return result
    operation = run_azure(azure_command(target, action, subscription), MUTATION_TIMEOUT)
    if operation.returncode:
        azure_failure(operation.stderr)
    confirmed = power_state(target, subscription)
    if confirmed != desired:
        raise PowerError("CONFIRMATION_FAILED", "Azure completed but the exact requested power state was not confirmed.")
    result.update(power_state=confirmed, changed=True, outcome="changed")
    return result


def write_outputs(result, resolve=False):
    filename = os.environ.get("GITHUB_OUTPUT")
    if not filename:
        return
    if resolve:
        values = {**result, "target": json.dumps(result, sort_keys=True)}
    else:
        values = {key: result[key] for key in ("power_state", "initial_state", "outcome")}
        values["requested_state"] = result["requested_state"] or "observe"
    with open(filename, "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--validate-registry", action="store_true")
    mode.add_argument("--resolve-target", action="store_true")
    parser.add_argument("--registry", type=Path, default=ROOT / "infra" / "regions.json")
    parser.add_argument("--environment")
    parser.add_argument("--action", choices=("status", "start", "deallocate"))
    parser.add_argument("--subscription")
    args = parser.parse_args(argv)
    if args.validate_registry:
        if args.environment or args.action or args.subscription:
            parser.error("--validate-registry cannot be combined with a target, action, or subscription")
    elif not args.environment:
        parser.error("--environment is required; only one enabled environment may be targeted")
    elif args.resolve_target:
        if args.action or args.subscription:
            parser.error("--resolve-target is credential-free and cannot be combined with action or subscription")
    elif not args.action:
        parser.error("--action is required")
    try:
        if args.subscription is not None and (
                not args.subscription.strip() or args.subscription != args.subscription.strip()
                or args.subscription.startswith("-") or any(ord(char) < 32 or ord(char) == 127 for char in args.subscription)):
            raise PowerError("INVALID_SUBSCRIPTION", "Subscription must be a non-empty identifier or name.")
        project = os.environ.get("PROJECT_NAME", "plaz")
        regions = validate_registry(args.registry, project)
        if args.validate_registry:
            result = {"status": "valid", "regions": len(regions),
                      "enabled_regions": sum(region["enabled"] for region in regions)}
        else:
            target = resolve_target(regions, args.environment, project)
            result = target if args.resolve_target else operate(target, args.action, args.subscription)
            write_outputs(result, resolve=args.resolve_target)
        print(json.dumps(result, sort_keys=True))
        return 0
    except PowerError as exc:
        print(json.dumps({"status": "error", "error": exc.code, "message": str(exc)}), file=sys.stderr)
        return 1
    except OSError:
        print(json.dumps({"status": "error", "error": "OUTPUT_ERROR",
                          "message": "Unable to write Actions outputs."}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

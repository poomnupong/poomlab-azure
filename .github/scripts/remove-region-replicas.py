#!/usr/bin/env python3
"""Remove retired-region replicas, retaining image versions and other targets."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time


class ReplicaError(RuntimeError):
    pass


def normalize_location(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9 ]*", value):
        raise ReplicaError("Invalid Azure region name")
    return value.replace(" ", "").lower()


def plan_removal(versions, removed, active):
    if not removed or removed & active:
        raise ReplicaError("Removal must name retired regions only, never enabled regions")
    if not isinstance(versions, list):
        raise ReplicaError("Azure did not return an image-version list")
    plans = []
    names = set()
    for version in versions:
        if not isinstance(version, dict) or not isinstance(version.get("name"), str):
            raise ReplicaError("Invalid image-version metadata")
        name = version["name"]
        if name in names or not re.fullmatch(r"\d+\.\d+\.\d+", name):
            raise ReplicaError("Invalid or duplicate image-version name")
        names.add(name)
        profile = version.get("publishingProfile")
        regions = profile.get("targetRegions") if isinstance(profile, dict) else None
        if not isinstance(regions, list) or not regions:
            raise ReplicaError(f"{name}: missing target-region metadata")
        if any(not isinstance(region, dict) or "name" not in region for region in regions):
            raise ReplicaError(f"{name}: malformed target region")
        locations = [normalize_location(region["name"]) for region in regions]
        if len(locations) != len(set(locations)):
            raise ReplicaError(f"{name}: duplicate target region")
        if not removed.intersection(locations):
            continue
        source = normalize_location(version.get("location"))
        if source in removed or source not in locations:
            raise ReplicaError(f"{name}: refusing to remove the source region")
        if version.get("provisioningState") != "Succeeded":
            raise ReplicaError(f"{name}: image version is not in Succeeded state")
        safety = version.get("safetyProfile") or {}
        if not isinstance(safety, dict):
            raise ReplicaError(f"{name}: invalid safety profile")
        allow_delete = safety.get("allowDeletionOfReplicatedLocations")
        if allow_delete is not None and not isinstance(allow_delete, bool):
            raise ReplicaError(f"{name}: invalid replica-deletion safety setting")
        plans.append({
            "name": name,
            "regions": [
                region for region, location in zip(regions, locations)
                if location not in removed
            ],
            "restore_protection": allow_delete is not True,
        })
    return plans


class Azure:
    def __init__(self, args):
        self.scope = [
            "--resource-group", args.resource_group,
            "--gallery-name", args.gallery_name,
            "--gallery-image-definition", args.image_definition,
        ]
        self.subscription = ["--subscription", args.subscription] if args.subscription else []

    def command(self, operation, arguments=(), *, output="none"):
        command = [
            "az", "sig", "image-version", operation, *self.scope,
            *arguments, *self.subscription, "--only-show-errors", "--output", output,
        ]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ReplicaError(f"Azure image-version {operation} could not complete: {error}") from error
        if result.returncode:
            raise ReplicaError(f"Azure image-version {operation} failed: {result.stderr.strip()}")
        if output == "json":
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError as error:
                raise ReplicaError(f"Azure image-version {operation} returned invalid JSON") from error
        return None

    def versions(self):
        return self.command("list", output="json")

    def update(self, name, properties):
        self.command("update", [
            "--gallery-image-version", name,
            "--set", *properties, "--no-wait",
        ])

    def wait(self, plans, *, protection=False):
        deadline = time.monotonic() + 900
        pending = {plan["name"]: plan for plan in plans}
        while pending:
            versions = self.versions()
            if not isinstance(versions, list):
                raise ReplicaError("Azure returned invalid image-version inventory while waiting")
            found = set()
            for version in versions:
                if not isinstance(version, dict) or not isinstance(version.get("name"), str):
                    raise ReplicaError("Azure returned malformed image-version metadata while waiting")
                name = version["name"]
                if name not in pending:
                    continue
                if name in found:
                    raise ReplicaError(f"{name}: duplicate image-version metadata")
                found.add(name)
                state = version.get("provisioningState")
                if state in {"Failed", "Canceled"}:
                    raise ReplicaError(f"{name}: Azure provisioning {state}")
                if state not in {"Succeeded", "Creating", "Updating", "Deleting", "Migrating"}:
                    raise ReplicaError(f"{name}: unexpected provisioning state {state!r}")
                if state == "Deleting":
                    raise ReplicaError(f"{name}: image version is unexpectedly being deleted")
                if state != "Succeeded":
                    continue
                profile = version.get("publishingProfile")
                safety = version.get("safetyProfile")
                if protection:
                    matches = isinstance(safety, dict) and safety.get("allowDeletionOfReplicatedLocations") is False
                else:
                    actual = profile.get("targetRegions") if isinstance(profile, dict) else None
                    matches = actual == pending[name]["regions"]
                if matches:
                    del pending[name]
            missing = set(pending) - found
            if missing:
                raise ReplicaError(f"Image versions disappeared while waiting: {', '.join(sorted(missing))}")
            if pending:
                if time.monotonic() >= deadline:
                    raise ReplicaError(f"Timed out waiting for image versions: {', '.join(sorted(pending))}")
                time.sleep(15)


def remove_replicas(azure, plans):
    attempted = []
    error = None
    try:
        for plan in plans:
            attempted.append(plan)
            azure.update(plan["name"], [
                "safetyProfile.allowDeletionOfReplicatedLocations=true",
                "publishingProfile.targetRegions=" + json.dumps(plan["regions"], separators=(",", ":")),
            ])
        azure.wait(attempted)
    except ReplicaError as caught:
        error = caught

    # A temporary Azure safety opt-in is required to remove replicated locations.
    # Restore its effective original value even after a partially failed update.
    protected = []
    restore_errors = []
    for plan in attempted:
        if plan["restore_protection"]:
            try:
                azure.update(plan["name"], ["safetyProfile.allowDeletionOfReplicatedLocations=false"])
                protected.append(plan)
            except ReplicaError as caught:
                restore_errors.append(str(caught))
    if protected:
        try:
            azure.wait(protected, protection=True)
        except ReplicaError as caught:
            restore_errors.append(str(caught))
    if error or restore_errors:
        messages = ([str(error)] if error else []) + restore_errors
        raise ReplicaError("; ".join(messages))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--gallery-name", required=True)
    parser.add_argument("--image-definition", required=True)
    parser.add_argument("--removed-locations", required=True, help="JSON array of retired Azure locations")
    parser.add_argument("--subscription")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        for value in (args.resource_group, args.gallery_name, args.image_definition):
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", value) or value.lower() in {"none", "null"}:
                raise ReplicaError("Missing or invalid gallery deployment output")
        removed = json.loads(args.removed_locations)
        if not isinstance(removed, list) or any(not isinstance(value, str) for value in removed):
            raise ReplicaError("--removed-locations must be a JSON array of location names")
        root = Path(__file__).resolve().parents[2]
        validation = subprocess.run(
            [sys.executable, str(root / ".github/scripts/gateway-power.py"), "--validate-registry"],
            check=False, capture_output=True, text=True, timeout=30,
        )
        if validation.returncode:
            raise ReplicaError(f"Region registry validation failed; no replicas changed: {validation.stderr.strip()}")
        registry = json.loads((root / "infra/regions.json").read_text())
        active = {region["location"] for region in registry["regions"] if region["enabled"]}
        azure = Azure(args)
        plans = plan_removal(azure.versions(), {normalize_location(value) for value in removed}, active)
        if not args.dry_run:
            remove_replicas(azure, plans)
            if plan_removal(azure.versions(), {normalize_location(value) for value in removed}, active):
                raise ReplicaError("Retired-region replicas still exist after cleanup")
        print(json.dumps({
            "dry_run": args.dry_run,
            "removed_locations": removed,
            "image_versions": [plan["name"] for plan in plans],
            "version_count": len(plans),
        }, indent=2))
        return 0
    except (ReplicaError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

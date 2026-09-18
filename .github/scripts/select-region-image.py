#!/usr/bin/env python3
"""Select the newest blessed image replicated to a gateway's region."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import sys


def select_image(versions, location):
    if not isinstance(versions, list):
        raise ValueError("Azure did not return an image-version list")
    candidates = []
    for version in versions:
        if not isinstance(version, dict):
            raise ValueError("Azure returned malformed image-version metadata")
        tags = version.get("tags") or {}
        if not isinstance(tags, dict):
            raise ValueError("Azure returned malformed image tags")
        if tags.get("blessed") != "true" or version.get("provisioningState") != "Succeeded":
            continue
        profile = version.get("publishingProfile")
        if not isinstance(profile, dict) or not isinstance(profile.get("targetRegions"), list):
            raise ValueError("Blessed image is missing replication metadata")
        targets = profile["targetRegions"]
        if any(not isinstance(target, dict) or not isinstance(target.get("name"), str) for target in targets):
            raise ValueError("Blessed image has invalid target regions")
        if location not in {target["name"].replace(" ", "").lower() for target in targets}:
            continue
        if any(not isinstance(version.get(field), str) or not version[field] or
               "\n" in version[field] or "\r" in version[field] for field in ("id", "name")):
            raise ValueError("Blessed image is missing a safe ID or name")
        date = profile.get("publishedDate")
        if not isinstance(date, str):
            raise ValueError("Blessed image has no publication date")
        published = datetime.fromisoformat(date.replace("Z", "+00:00"))
        if published.tzinfo is None:
            raise ValueError("Blessed image publication date has no timezone")
        candidates.append((published, version))
    return max(candidates, key=lambda item: item[0])[1] if candidates else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--location", required=True)
    parser.add_argument("--versions", type=Path, required=True)
    args = parser.parse_args()
    try:
        image = select_image(json.loads(args.versions.read_text()), args.location)
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f"image_ready={'true' if image else 'false'}\n")
        if image and os.environ.get("GITHUB_ENV"):
            with open(os.environ["GITHUB_ENV"], "a") as output:
                output.write(f"NIXOS_IMAGE_ID={image['id']}\nBLESSED_VERSION={image['name']}\n")
        print(json.dumps({"image_ready": image is not None, "image_id": image["id"] if image else None}))
        return 0
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

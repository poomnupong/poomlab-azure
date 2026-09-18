#!/usr/bin/env python3
"""Check the effective CI credential without exposing tokens or response bodies."""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Redirect refused", headers, fp)


def open_github_url(request, timeout):
    return urllib.request.build_opener(NoRedirect()).open(request, timeout=timeout)


def check_auth(environ, open_url=open_github_url):
    token = environ.get("GH_TOKEN", "")
    repository = environ.get("GITHUB_REPOSITORY", "")
    revision = environ.get("GITHUB_SHA", "")
    if not token.strip():
        raise ValueError("GH_PAT is missing or empty. Update the Actions secret before retrying.")
    if not re.fullmatch(r"[A-Za-z0-9_]+", token):
        raise ValueError("GH_PAT contains invalid characters. Save only the token value in the Actions secret.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not revision:
        raise ValueError("GITHUB_REPOSITORY and GITHUB_SHA must identify the repository revision.")

    query = urllib.parse.urlencode({"ref": revision})
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/contents/nixos/flake.nix?{query}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "poomlab-azure-credential-preflight",
        },
    )
    try:
        with open_url(request, timeout=30) as response:
            content = json.load(response)
    except urllib.error.HTTPError as error:
        messages = {
            401: "GH_PAT was rejected by GitHub. Check expiration or revocation and replace it if needed.",
            403: "GitHub denied GH_PAT access. Check permissions, authorization, and API rate limits.",
            404: "GH_PAT cannot read the requested repository file. Check repository access, Contents read permission, and the revision.",
            429: "GitHub rate-limited the credential check. Retry after the rate limit resets.",
        }
        message = messages.get(error.code, f"GitHub credential check failed with HTTP {error.code}.")
        raise ValueError(message) from None
    except (urllib.error.URLError, TimeoutError):
        raise ValueError("GitHub credential check encountered a network failure or timeout; token validity is unverified.") from None
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ValueError("GitHub credential check returned an invalid response; token validity is unverified.") from None

    if not isinstance(content, dict) or content.get("type") != "file" or not content.get("sha"):
        raise ValueError("GitHub credential check did not return the expected repository file.")


def main():
    try:
        check_auth(os.environ)
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    print("GH_PAT authenticated successfully and can read this repository revision.")
    print("PR push/write permissions are verified by the updater, not this read-only check.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

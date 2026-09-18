import importlib.util
import io
import json
from pathlib import Path
import unittest
import urllib.error


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "github_auth", ROOT / ".github/scripts/check-github-auth.py"
)
AUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTH)


class GitHubAuthTests(unittest.TestCase):
    def setUp(self):
        self.env = {
            "GH_TOKEN": "github_pat_fixture_only",
            "GITHUB_REPOSITORY": "owner/repo",
            "GITHUB_SHA": "a" * 40,
        }

    def test_reads_exact_revision_with_effective_token(self):
        def open_url(request, timeout):
            self.assertEqual(
                request.full_url,
                "https://api.github.com/repos/owner/repo/contents/nixos/flake.nix?ref=" + "a" * 40,
            )
            self.assertEqual(request.get_header("Authorization"), "Bearer " + self.env["GH_TOKEN"])
            self.assertEqual(timeout, 30)
            return io.BytesIO(json.dumps({"type": "file", "sha": "b" * 40}).encode())

        AUTH.check_auth(self.env, open_url)

    def test_missing_or_invalid_token_never_contacts_github(self):
        for value in ("", " ", "github_pat_fixture_only\n", "Bearer github_pat_fixture_only"):
            with self.subTest(value=value):
                env = dict(self.env, GH_TOKEN=value)
                with self.assertRaisesRegex(ValueError, "GH_PAT") as error:
                    AUTH.check_auth(env, lambda *args, **kwargs: self.fail("Unexpected request"))
                self.assertNotIn("github_pat_fixture_only", str(error.exception))

    def test_invalid_repository_context(self):
        for name, value in (("GITHUB_REPOSITORY", "../bad/repo"), ("GITHUB_SHA", "")):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "repository revision"):
                AUTH.check_auth(dict(self.env, **{name: value}))

    def test_http_failures_are_distinct_and_do_not_expose_response(self):
        for status, expected in (
            (401, "rejected"), (403, "denied"), (404, "cannot read"),
            (429, "rate-limited"), (503, "HTTP 503"), (302, "HTTP 302"),
        ):
            with self.subTest(status=status):
                def reject(request, timeout):
                    raise urllib.error.HTTPError(
                        request.full_url, status, self.env["GH_TOKEN"], {}, None
                    )

                with self.assertRaisesRegex(ValueError, expected) as error:
                    AUTH.check_auth(self.env, reject)
                self.assertNotIn(self.env["GH_TOKEN"], str(error.exception))

    def test_network_error_is_not_reported_as_expired_token(self):
        for failure in (urllib.error.URLError("fixture"), TimeoutError()):
            def unavailable(request, timeout):
                raise failure

            with self.subTest(failure=failure), self.assertRaisesRegex(ValueError, "network failure"):
                AUTH.check_auth(self.env, unavailable)

    def test_malformed_success_response_fails(self):
        for body in (b"not json", b"null", b"[]", b'{"type":"dir"}', b'{"type":"file"}'):
            with self.subTest(body=body), self.assertRaises(ValueError):
                AUTH.check_auth(self.env, lambda *args, **kwargs: io.BytesIO(body))

    def test_redirect_is_refused_without_forwarding_credentials(self):
        with self.assertRaises(urllib.error.HTTPError):
            AUTH.NoRedirect().redirect_request(
                urllib.request.Request("https://api.github.com/test"),
                None, 302, "Found", {}, "https://example.invalid/",
            )

    def test_updater_checks_pat_before_nix_without_persisting_checkout_token(self):
        source = (ROOT / ".github/workflows/update-flake-lock.yml").read_text()
        steps = source.split("    steps:", 1)[1]
        checkout = steps.split("      - name: Verify GitHub credential", 1)[0]
        self.assertIn("persist-credentials: false", checkout)
        self.assertNotIn("secrets.GH_PAT", checkout)
        self.assertLess(steps.index("check-github-auth.py"), steps.index("Install Nix"))
        self.assertIn("token: ${{ secrets.GH_PAT }}", steps.split("Open / update pull request", 1)[1])

    def test_image_preflight_precedes_azure_in_both_production_jobs(self):
        source = (ROOT / ".github/workflows/image-bake.yml").read_text()
        for job in ("publish", "smoke-tier2"):
            with self.subTest(job=job):
                section = source.split(f"  {job}:\n", 1)[1]
                self.assertLess(section.index("check-github-auth.py"), section.index("azure/login@"))
                self.assertIn("environment: production", section)
                self.assertIn("if: github.ref == 'refs/heads/main'", section)
        build = source.split("  build:\n", 1)[1].split("  publish:\n", 1)[0]
        self.assertNotIn("secrets.GH_PAT", build)
        self.assertNotIn("needs:", build)


if __name__ == "__main__":
    unittest.main()

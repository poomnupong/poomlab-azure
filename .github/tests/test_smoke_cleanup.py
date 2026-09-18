import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SmokeCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / ".github/workflows/image-bake.yml").read_text()
        step = source.split("      - name: Tear down smoke RG\n", 1)[1].split("      - name:", 1)[0]
        cls.script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        assert "if: always()" in step
        assert "timeout-minutes: 6" in step

    def cleanup(self, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "calls"
            az = root / "az"
            az.write_text(
                "#!/bin/sh\n"
                'printf "%s\\n" "$*" >> "$AZ_LOG"\n'
                'case "$1 $2" in\n'
                '  "group exists") printf "%s\\n" "$EXISTS"; exit "${EXISTS_EXIT:-0}";;\n'
                '  "group delete") exit "${DELETE_EXIT:-0}";;\n'
                '  "group wait") exit "${WAIT_EXIT:-0}";;\n'
                '  *) exit 99;;\n'
                "esac\n"
            )
            az.chmod(0o700)
            env = {
                **os.environ,
                "PATH": f"{directory}:{os.environ['PATH']}",
                "AZ_LOG": str(log),
                "EXISTS": "true",
                "SMOKE_RG": "rg-plaz-smoke-fixture",
                **overrides,
            }
            result = subprocess.run(
                ["bash", "-c", self.script], env=env, capture_output=True, text=True, timeout=5
            )
            return result, log.read_text() if log.exists() else ""

    def test_waits_for_confirmed_deletion(self):
        result, calls = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("group delete --name rg-plaz-smoke-fixture --yes --no-wait", calls)
        self.assertIn("group wait --name rg-plaz-smoke-fixture --deleted --interval 10 --timeout 300", calls)
        self.assertIn("deletion completed", result.stdout)

    def test_delete_and_wait_failures_do_not_claim_completion(self):
        for name in ("DELETE_EXIT", "WAIT_EXIT", "EXISTS_EXIT"):
            with self.subTest(name=name):
                result, calls = self.cleanup(**{name: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("deletion completed", result.stdout)
                if name != "WAIT_EXIT":
                    self.assertNotIn("group wait", calls)

    def test_already_absent_requires_no_mutation(self):
        result, calls = self.cleanup(EXISTS="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already absent", result.stdout)
        self.assertNotIn("group delete", calls)

    def test_missing_resource_output_does_not_target_any_group(self):
        result, calls = self.cleanup(SMOKE_RG="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "")

    def test_unknown_existence_result_fails_without_deleting(self):
        result, calls = self.cleanup(EXISTS="unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error::", result.stdout)
        self.assertNotIn("group delete", calls)

    def test_actual_wait_step_reserves_cleanup_time_and_caps_observation(self):
        source = (ROOT / ".github/workflows/image-bake.yml").read_text()
        step = source.split("      - name: Wait for Comin to complete first deployment\n", 1)[1]
        script = textwrap.dedent(step.split("      - name:", 1)[0].split("        run: |\n", 1)[1])
        for remaining, expected in ((1900, 1800), (300, 300), (0, None), (-1, None)):
            with self.subTest(remaining=remaining), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                calls = root / "calls"
                for name, content in {
                    "date": "#!/bin/sh\nprintf '1000\\n'\n",
                    "python3": '#!/bin/sh\nprintf "%s\\n" "$*" > "$CALLS"\n',
                }.items():
                    path = root / name
                    path.write_text(content)
                    path.chmod(0o700)
                env = {
                    **os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                    "SMOKE_OBSERVATION_DEADLINE": str(1000 + remaining), "CALLS": str(calls),
                }
                result = subprocess.run(
                    ["bash", "-c", script], env=env, capture_output=True, text=True, timeout=5
                )
                if expected is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("reserving time for cleanup", result.stdout)
                    self.assertFalse(calls.exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"--wait --timeout-seconds {expected}", calls.read_text())


if __name__ == "__main__":
    unittest.main()

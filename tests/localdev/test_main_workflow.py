"""Unified regression entrypoint orchestration; commands are explicit test doubles."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/localdev/test.sh"


class MainWorkflowTests(unittest.TestCase):
    def run_script(self, failure=""):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo with spaces"
            entry = root / "tools/localdev/test.sh"
            entry.parent.mkdir(parents=True)
            entry.write_bytes(SCRIPT.read_bytes())
            bin_dir = Path(temporary) / "bin"
            bin_dir.mkdir()
            trace = Path(temporary) / "trace"
            for name in ["swift", "python3"]:
                stub = bin_dir / name
                stub.write_text(
                    '#!/bin/bash\n'
                    'printf "%s|%s\\n" "${0##*/}" "$*" >> "$TRACE"\n'
                    'case "${0##*/}:$*" in\n'
                    '  swift:*"-c release"*) [[ "$FAILURE" != release ]] || exit 23 ;;\n'
                    '  swift:*) [[ "$FAILURE" != debug ]] || exit 22 ;;\n'
                    'esac\n'
                    'exit 0\n'
                )
                stub.chmod(0o700)
            env = dict(os.environ, PATH=f"{bin_dir}:/usr/bin:/bin", TRACE=str(trace), FAILURE=failure)
            result = subprocess.run(["/bin/bash", str(entry)], env=env, capture_output=True, text=True)
            return result, trace.read_text().splitlines(), root

    def test_success_runs_debug_release_and_contracts_in_order(self):
        result, trace, root = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, [
            f"swift|test --package-path {root}/Packages/AppCore -Xswiftc -warnings-as-errors",
            f"swift|test --package-path {root}/Packages/AppCore -c release -Xswiftc -warnings-as-errors",
            f"python3|-m unittest discover -s {root}/tests/localdev -v",
        ])
        self.assertIn("mac_gui=NOT_RUN", result.stdout)
        self.assertIn("live_keychain=NOT_RUN", result.stdout)

    def test_debug_failure_stops_without_claiming_pass(self):
        result, trace, _ = self.run_script("debug")
        self.assertEqual(result.returncode, 22)
        self.assertEqual(len(trace), 1)
        self.assertNotIn("core=PASS", result.stdout)

    def test_release_failure_stops_before_contracts(self):
        result, trace, _ = self.run_script("release")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(len(trace), 2)
        self.assertNotIn("contracts=PASS", result.stdout)

    def test_shell_syntax(self):
        subprocess.run(["/bin/bash", "-n", str(SCRIPT)], capture_output=True, check=True)


if __name__ == "__main__":
    unittest.main()

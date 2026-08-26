import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CallaCourseWrapperTests(unittest.TestCase):
    def test_refresh_runtime_without_stdin_sends_empty_object_payload(self):
        script = Path(__file__).resolve().parents[2] / "scripts" / "calla-course.sh"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            capture = root / "request.json"
            fake_ssh = root / "ssh"
            fake_ssh.write_text(
                "#!/bin/sh\n"
                "for arg do last=$arg; done\n"
                "case $last in *calla-course) cat > \"$TEST_CAPTURE\";; esac\n",
                encoding="utf-8",
            )
            fake_ssh.chmod(0o700)
            environment = os.environ | {
                "PATH": f"{root}:{os.environ['PATH']}",
                "TEST_CAPTURE": str(capture),
            }
            completed = subprocess.run(
                [str(script), "refresh-runtime"], input="", text=True,
                capture_output=True, env=environment, check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(
                json.loads(capture.read_text(encoding="utf-8")),
                {"version": 1, "command": "refresh-runtime", "payload": {}},
            )


if __name__ == "__main__":
    unittest.main()

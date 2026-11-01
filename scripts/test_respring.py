"""Run only respring launch/fallback regressions, without spawning sbreload."""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
if sys.platform != "darwin":
    raise SystemExit("Native respring tests require macOS and the Xcode command-line tools.")

with tempfile.TemporaryDirectory(prefix="netshield-respring-tests-") as directory:
    executable = pathlib.Path(directory) / "respring-tests"
    subprocess.run([
        "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
        "-DNS_TESTING=1", '-DNS_JAILBREAK_TYPE="rootful"',
        "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
        "Tests/RespringTests.m", "App/NSRespring.m", "-o", str(executable),
    ], cwd=ROOT, check=True)
    subprocess.run([str(executable)], cwd=ROOT, check=True)

"""Compile and run the production shared-code regression tests on macOS."""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
if sys.platform != "darwin":
    raise SystemExit("Native regression tests require macOS and the Xcode command-line tools.")

sources = [
    "Tests/RegressionTests.m",
    "App/NSFilterRemoval.m",
    "Shared/NSPolicy.m",
    "Shared/NSPermissionQueue.m",
    "Shared/NSPolicyCache.m",
    "Shared/NSStoreLock.m",
    "Shared/NSStore.m",
    "FilterControl/NSPermissionNotifications.m",
]
with tempfile.TemporaryDirectory(prefix="netshield-tests-") as directory:
    executable = pathlib.Path(directory) / "regression-tests"
    subprocess.run([
        "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
        "-DNS_TESTING=1", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
        "-framework", "Foundation", "-framework", "UserNotifications",
        *sources, "-o", str(executable),
    ], cwd=ROOT, check=True)
    subprocess.run([str(executable)], cwd=ROOT, check=True)

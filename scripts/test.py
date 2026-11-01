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
    "Tests/RecoveryTests.m",
    "Tests/BootPolicyTests.m",
    "App/NSFilterRemoval.m",
    "App/NSFilterRestart.m",
    "App/NSFilterBootPolicy.m",
    "Shared/NSPolicy.m",
    "Shared/NSPermissionQueue.m",
    "Shared/NSPolicyCache.m",
    "Shared/NSStoreLock.m",
    "Shared/NSStore.m",
    "FilterControl/NSPermissionNotifications.m",
    "FilterControl/NSDomainResolver.m",
]
with tempfile.TemporaryDirectory(prefix="netshield-tests-") as directory:
    # Apple SDKs expose DNSService APIs through the automatically linked
    # libSystem; there is no separate libdns_sd to request here.
    for experiment in (0, 1):
        executable = pathlib.Path(directory) / f"regression-tests-{experiment}"
        subprocess.run([
            "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
            "-DNS_TESTING=1", f"-DNS_BOOT_POLICY_EXPERIMENT={experiment}",
            "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
            "-framework", "Foundation", "-framework", "UserNotifications",
            *sources, "-o", str(executable),
        ], cwd=ROOT, check=True)
        subprocess.run([str(executable)], cwd=ROOT, check=True)

# Keep the isolated launch tests in the normal native suite as well as runnable
# on their own. Their injected launcher never executes the device respring tool.
subprocess.run([sys.executable, str(ROOT / "scripts/test_respring.py")], cwd=ROOT, check=True)

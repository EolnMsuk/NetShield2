"""Compile and run the production shared-code regression tests on macOS."""
import argparse
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
if sys.platform != "darwin":
    raise SystemExit("Native regression tests require macOS and the Xcode command-line tools.")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sanitizers', choices=('address,undefined', 'thread'))
options = parser.parse_args()
sanitizers = [f'-fsanitize={options.sanitizers}', '-fno-omit-frame-pointer', '-g'] if options.sanitizers else []

sources = [
    "Tests/RegressionTests.m",
    "Tests/RecoveryTests.m",
    "Tests/BootPolicyTests.m",
    "Tests/ConfigurationTests.m",
    "Tests/HardeningTests.m",
    "App/NSConfigurationCoordinator.m",
    "App/NSReleaseFetch.m",
    "App/NSFilterRemoval.m",
    "App/NSFilterRestart.m",
    "App/NSFilterBootPolicy.m",
    "Shared/NSPolicy.m",
    "Shared/NSPermissionQueue.m",
    "Shared/NSPolicyCache.m",
    "Shared/NSPolicyReader.m",
    "Shared/NSStoreLock.m",
    "Shared/NSBoundedFile.m",
    "Shared/NSMonitorSchema.m",
    "Shared/NSExport.m",
    "Shared/NSStore.m",
    "FilterControl/NSPermissionNotifications.m",
    "FilterControl/NSDomainResolver.m",
    "FilterControl/NSProviderWorkQueue.m",
]
with tempfile.TemporaryDirectory(prefix="netshield-tests-") as directory:
    # Apple SDKs expose DNSService APIs through the automatically linked
    # libSystem; there is no separate libdns_sd to request here.
    executable = pathlib.Path(directory) / "regression-tests"
    subprocess.run([
        "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
        "-DNS_TESTING=1",
        "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
        "-framework", "Foundation", "-framework", "UserNotifications",
        *sanitizers, *sources, "-o", str(executable),
    ], cwd=ROOT, check=True)
    subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=180)

# Keep the isolated launch tests in the normal native suite as well as runnable
# on their own. Their injected launcher never executes the device respring tool.
subprocess.run([sys.executable, str(ROOT / "scripts/test_respring.py")], cwd=ROOT, check=True)

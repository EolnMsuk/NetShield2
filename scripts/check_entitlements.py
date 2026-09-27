"""Check the actual Mach-O entitlements exported by ldid in CI."""
import pathlib
import plistlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
component = sys.argv[2].split('/')[-1]
directory = {'NetShield2': 'App', 'NetShield2Data': 'FilterData', 'NetShield2Control': 'FilterControl'}[component]
actual = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
expected = plistlib.loads((root / directory / 'Entitlements.plist').read_bytes())
if actual != expected:
    raise SystemExit(f'Entitlement mismatch in {component}')
print(f'Validated signed entitlements for {component}; OS acceptance still requires device testing')

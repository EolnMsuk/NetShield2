import pathlib
import plistlib
import argparse

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('plist', type=pathlib.Path)
parser.add_argument('component')
parser.add_argument('--scheme', choices=('rootless', 'roothide'), default='rootless')
args = parser.parse_args()
component = args.component.split('/')[-1]
directory = {'NetShield2': 'App', 'NetShield2Data': 'FilterData', 'NetShield2Control': 'FilterControl'}[component]
actual = plistlib.loads(args.plist.read_bytes())
filename = 'Entitlements-roothide.plist' if args.scheme == 'roothide' else 'Entitlements.plist'
expected = plistlib.loads((root / directory / filename).read_bytes())
if actual != expected:
    raise SystemExit(f'Entitlement mismatch in {component}')
print(f'Validated {args.scheme} signed entitlements for {component}')

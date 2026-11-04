"""Syntax-only iOS check with a local libclang wheel, resource headers and SDK."""
import argparse
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sources', type=pathlib.Path, default=ROOT)
parser.add_argument('--toolchain', type=pathlib.Path, default=ROOT / '.theos-toolchain')
parser.add_argument('--scheme', choices=('rootless', 'roothide', 'rootful'), default='rootless')
options = parser.parse_args()
root = options.sources.resolve()
toolchain = options.toolchain.resolve()
sdk = toolchain / 'iPhoneOS16.5.sdk'
resources = toolchain / 'clang-resource'
if not all(path.is_dir() for path in (sdk, resources, toolchain / 'python/clang')):
    raise SystemExit('Syntax check requires the bundled iPhoneOS SDK, clang resources and Python libclang.')
sys.path.insert(0, str(toolchain / 'python'))
from clang import cindex

index = cindex.Index.create()
args = ['-target', 'arm64-apple-ios15.0', '-isysroot', str(sdk), '-resource-dir', str(resources),
        f'-DNS_JAILBREAK_TYPE="{options.scheme}"', '-fobjc-arc', '-fblocks', '-x', 'objective-c',
        '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Werror=unguarded-availability']
failed = False
count = 0
for folder in ('Shared', 'App', 'FilterControl', 'FilterData', 'Tests'):
    for source in sorted((root / folder).glob('*.m')):
        count += 1
        tu = index.parse(str(source), args=args + (['-DNS_TESTING=1'] if folder == 'Tests' else []))
        for diagnostic in tu.diagnostics:
            print(diagnostic)
            failed |= diagnostic.severity >= cindex.Diagnostic.Warning
if not count:
    raise SystemExit('No Objective-C translation units found.')
if failed:
    raise SystemExit(1)
print(f'Parsed {count} Objective-C translation units for arm64 iOS 15 ({options.scheme}); no diagnostics. Syntax only.')

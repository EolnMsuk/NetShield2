"""Tie each final deb to source, toolchain inputs and the host tool versions."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
from sync_version import release_metadata
from prepare_package import PACKAGE_ARCHITECTURES


def manifest(package, source, scheme, theos, sdk, tools):
    if not re.fullmatch(r'[0-9a-f]{40}', source) or not re.fullmatch(r'[0-9a-f]{40}', theos):
        raise ValueError('Source and Theos revisions must be complete commit SHAs')
    if not re.fullmatch(r'[0-9a-f]{64}', sdk):
        raise ValueError('Expected the pinned SDK SHA-256')
    metadata = release_metadata()
    expected = f"{metadata['Package']}_{metadata['Version']}_{scheme}.deb"
    if package.name != expected or not package.is_file() or package.is_symlink():
        raise ValueError('Expected the final regular deb for this variant')
    data = package.read_bytes()
    if not data:
        raise ValueError('Empty deb')
    return dict(schema=1, source=source, version=metadata['Version'], scheme=scheme,
                package=package.name, size=len(data), sha256=hashlib.sha256(data).hexdigest(),
                theos=theos, sdk_sha256=sdk, tools=tools)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', required=True, type=pathlib.Path)
    parser.add_argument('--source', required=True)
    parser.add_argument('--scheme', choices=PACKAGE_ARCHITECTURES, required=True)
    parser.add_argument('--theos', required=True)
    parser.add_argument('--sdk', required=True)
    args = parser.parse_args()
    commands = [('clang', ['xcrun', 'clang', '--version']), ('make', ['gmake', '--version']),
                ('packages', ['brew', 'list', '--versions']), ('dpkg', ['dpkg-deb', '--version']),
                ('signer', ['ldid', '-h'])]
    tools = {'python': sys.version}
    for name, command in commands:
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        tools[name] = dict(status=result.returncode, output=(result.stdout + result.stderr)[:16384])
    output = manifest(args.package, args.source, args.scheme, args.theos, args.sdk, tools)
    args.package.with_name(args.package.name + '.manifest.json').write_text(
        json.dumps(output, sort_keys=True, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()

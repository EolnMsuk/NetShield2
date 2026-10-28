"""Synchronize bundle versions and expose control metadata to CI."""
import argparse
import pathlib
import plistlib
import re


ROOT = pathlib.Path(__file__).resolve().parents[1]


def release_metadata():
    metadata = dict(line.split(': ', 1) for line in
                    (ROOT / 'control').read_text().splitlines() if ': ' in line)
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', metadata.get('Version', '')):
        raise ValueError('control: Version must use major.minor.patch format')
    if not re.fullmatch(r'[a-z0-9][a-z0-9+.-]+', metadata.get('Package', '')):
        raise ValueError('control: invalid Package identifier')
    return metadata


def sync_versions():
    metadata = release_metadata()
    constants = (ROOT / 'Shared/NSConstants.h').read_text()
    engine = re.search(r'\bNSEngineVersion\s*=\s*(\d+)', constants)
    if engine is None:
        raise ValueError('Shared/NSConstants.h: missing NSEngineVersion')
    for directory in ('App', 'FilterData', 'FilterControl'):
        path = ROOT / directory / 'Resources/Info.plist'
        original = path.read_bytes()
        info = plistlib.loads(original)
        if (info.get('CFBundleShortVersionString') == metadata['Version'] and
                info.get('CFBundleVersion') == engine.group(1)):
            continue
        info['CFBundleShortVersionString'] = metadata['Version']
        info['CFBundleVersion'] = engine.group(1)
        path.write_bytes(plistlib.dumps(info, sort_keys=False))
    return metadata


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github-env', type=pathlib.Path,
                        help='Append package metadata to the GitHub Actions environment file')
    args = parser.parse_args()
    metadata = sync_versions()
    if args.github_env:
        with args.github_env.open('a', encoding='utf-8', newline='\n') as output:
            output.write(f'PACKAGE_VERSION={metadata["Version"]}\n')
            output.write(f'PACKAGE_ID={metadata["Package"]}\n')

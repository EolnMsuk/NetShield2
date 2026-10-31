"""Generate bundle metadata in build outputs and expose control metadata to CI."""
import argparse
import os
import pathlib
import plistlib
import re
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]


def release_metadata():
    metadata = dict(line.split(': ', 1) for line in
                    (ROOT / 'control').read_text().splitlines() if ': ' in line)
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', metadata.get('Version', '')):
        raise ValueError('control: Version must use major.minor.patch format')
    if not re.fullmatch(r'[a-z0-9][a-z0-9+.-]+', metadata.get('Package', '')):
        raise ValueError('control: invalid Package identifier')
    return metadata


def bundle_build_version():
    # Preserve the shipped monotonic engine-based convention (currently > 20000).
    # Marketing versions such as 2.x would compare lower during bundle upgrades.
    constants = (ROOT / 'Shared/NSConstants.h').read_text()
    engine = re.search(r'\bNSEngineVersion\s*=\s*(\d+)', constants)
    if engine is None:
        raise ValueError('Shared/NSConstants.h: missing NSEngineVersion')
    return engine.group(1)


def bundle_metadata(template, metadata=None):
    info = plistlib.loads(template.read_bytes())
    if 'CFBundleShortVersionString' in info or 'CFBundleVersion' in info:
        raise ValueError(f'{template}: version fields must be generated, not maintained in source')
    info['CFBundleShortVersionString'] = (metadata or release_metadata())['Version']
    info['CFBundleVersion'] = bundle_build_version()
    return info


def generate_bundle_metadata(template, output):
    if template.resolve() == output.resolve():
        raise ValueError('Generated bundle metadata must not overwrite its source template')
    data = plistlib.dumps(bundle_metadata(template), sort_keys=False)
    if output.is_file() and output.read_bytes() == data:
        output.chmod(0o644)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    # Unique temporary files and atomic replacement also support parallel builds.
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
        name = temporary.name
        temporary.write(data)
    try:
        # NamedTemporaryFile defaults to 0600; shipped bundle plists must be readable by iOS.
        os.chmod(name, 0o644)
        for attempt in range(10):
            try:
                os.replace(name, output)
                break
            except PermissionError:
                # Windows readers briefly deny replacement during concurrent generation.
                if os.name != 'nt' or attempt == 9:
                    raise
                time.sleep(0.01 * (attempt + 1))
    finally:
        pathlib.Path(name).unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github-env', type=pathlib.Path,
                        help='Append package metadata to the GitHub Actions environment file')
    parser.add_argument('--template', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if bool(args.template) != bool(args.output):
        parser.error('--template and --output must be supplied together')
    metadata = release_metadata()
    if args.template:
        generate_bundle_metadata(args.template, args.output)
    if args.github_env:
        with args.github_env.open('a', encoding='utf-8', newline='\n') as output:
            output.write(f'PACKAGE_VERSION={metadata["Version"]}\n')
            output.write(f'PACKAGE_ID={metadata["Package"]}\n')

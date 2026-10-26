"""Prepare staged maintainer scripts without modifying the rootless sources."""
import argparse
import pathlib


PACKAGE_ARCHITECTURES = {
    'rootless': 'iphoneos-arm64',
    'roothide': 'iphoneos-arm64e',
    'rootful': 'iphoneos-arm',
}


def maintainer_script(source, scheme):
    # Rootful uses / directly; RootHide resolves it within its relocated root.
    if scheme in ('roothide', 'rootful'):
        return source.replace(b'/var/jb/', b'/')
    if scheme == 'rootless':
        return source
    raise ValueError(f'Unsupported package scheme: {scheme}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', type=pathlib.Path, required=True)
    parser.add_argument('--scheme', choices=PACKAGE_ARCHITECTURES, required=True)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    for name in ('postinst', 'prerm'):
        source = (root / 'layout/DEBIAN' / name).read_bytes()
        (args.stage / 'DEBIAN' / name).write_bytes(maintainer_script(source, args.scheme))

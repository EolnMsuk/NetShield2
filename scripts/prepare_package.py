"""Prepare staged maintainer scripts without modifying the rootless sources."""
import argparse
import pathlib


def maintainer_script(source, scheme):
    # RootHide's bootstrap tools use paths relative to its relocated root.
    if scheme == 'roothide':
        return source.replace(b'/var/jb/', b'/')
    if scheme == 'rootless':
        return source
    raise ValueError(f'Unsupported package scheme: {scheme}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', type=pathlib.Path, required=True)
    parser.add_argument('--scheme', choices=('rootless', 'roothide'), required=True)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    for name in ('postinst', 'prerm'):
        source = (root / 'layout/DEBIAN' / name).read_bytes()
        (args.stage / 'DEBIAN' / name).write_bytes(maintainer_script(source, args.scheme))

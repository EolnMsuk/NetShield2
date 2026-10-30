"""Package exact staged bytes as a plain PoC; does not install or invoke TrollStore."""
import argparse
import hashlib
import json
import os
import pathlib
import stat
import zipfile
from check_tipa import APP, BUNDLES, audit_files, check_archive


def build(app, output):
    if app.is_symlink() or not app.is_dir():
        raise ValueError('Expected a real staged app directory, not a symlink')
    files = {}
    for path in sorted(app.rglob('*')):
        if path.is_symlink():
            raise ValueError(f'Plain bundle must not contain symlinks: {path}')
        if path.is_file():
            files[APP + path.relative_to(app).as_posix()] = path.read_bytes()
    audit_files(files)
    output.parent.mkdir(parents=True, exist_ok=True)
    executables = {APP + path + name for _, path, name in BUNDLES}
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, raw in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | (0o755 if name in executables else 0o644)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, raw)
    audit = check_archive(output)
    manifest = {
        'format': 1, 'purpose': 'Phase 0 UNVERIFIED plain TrollStore recovery PoC',
        'sourceRevision': os.environ.get('GITHUB_SHA', 'local-source-check'),
        'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
        'files': {name: hashlib.sha256(raw).hexdigest() for name, raw in sorted(files.items())},
        'audit': audit,
        'pending': ['GitHub build success', 'installed signing/registration audit',
                    'real stock-boot launch and NE authorization', 'traffic recovery',
                    'normal firewall operation in each jailbreak'],
    }
    output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n',
                                                   encoding='utf-8', newline='\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    build(args.app, args.output)

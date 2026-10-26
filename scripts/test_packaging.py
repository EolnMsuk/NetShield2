"""Check packaging CLIs with staged fixtures, including invalid rootful packages."""
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
# Independent expected outputs: a rootful deb still contains arm64 Mach-O files.
VARIANTS = (
    ('rootless', 'iphoneos-arm64', 'var/jb/'),
    ('roothide', 'iphoneos-arm64e', ''),
    ('rootful', 'iphoneos-arm', ''),
)
BUNDLES = (
    ('App', 'NetShield2', ''),
    ('FilterData', 'NetShield2Data', 'PlugIns/NetShield2Data.appex'),
    ('FilterControl', 'NetShield2Control', 'PlugIns/NetShield2Control.appex'),
)


def run(script, *arguments, error=None):
    result = subprocess.run([sys.executable, str(ROOT / 'scripts' / script), *arguments],
                            capture_output=True, text=True, timeout=30)
    if error is None:
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        assert result.returncode != 0 and error in result.stdout + result.stderr, result


sources = {name: (ROOT / 'layout/DEBIAN' / name).read_bytes()
           for name in ('postinst', 'prerm')}
with tempfile.TemporaryDirectory(prefix='netshield-packaging-') as directory:
    for scheme, architecture, prefix in VARIANTS:
        stage = pathlib.Path(directory) / scheme
        debian = stage / 'DEBIAN'
        debian.mkdir(parents=True)
        metadata = (ROOT / 'control').read_text().replace(
            'Architecture: iphoneos-arm\n', f'Architecture: {architecture}\n')
        control = debian / 'control'
        control.write_text(metadata, newline='\n')
        app = stage / (prefix + 'Applications/NetShield2.app')
        for source, binary, relative in BUNDLES:
            bundle = app / relative
            bundle.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / source / 'Resources/Info.plist', bundle / 'Info.plist')
            executable = bundle / binary
            # Only the Mach-O header is needed by the package layout validator.
            executable.write_bytes(struct.pack('<III', 0xfeedfacf, 0x100000c, 0))
            executable.chmod(0o755)
        arguments = ('--stage', str(stage), '--scheme', scheme)
        run('prepare_package.py', *arguments)
        for name in sources:
            script = debian / name
            script.chmod(0o755)
            content = script.read_bytes()
            assert f'/{prefix}Applications/NetShield2.app'.encode() in content
            assert f'/{prefix}usr/bin/uicache'.encode() in content
            if not prefix:
                assert b'/var/jb/' not in content
            else:
                assert content == sources[name]
        run('validate.py', *arguments)

        # Reject metadata from another variant even when the app layout matches.
        wrong_arch = 'iphoneos-arm64' if scheme == 'rootful' else 'iphoneos-arm'
        control.write_text(metadata.replace(f'Architecture: {architecture}',
                                           f'Architecture: {wrong_arch}'), newline='\n')
        run('validate.py', *arguments, error='Wrong staged package architecture')
        control.write_text(metadata, newline='\n')

        if scheme == 'rootful':
            # Rootless lifecycle paths must never ship inside a rootful package.
            (debian / 'prerm').write_bytes(sources['prerm'])
            run('validate.py', *arguments, error='Wrong rootful maintainer script: prerm')
            run('prepare_package.py', *arguments)
            misplaced = stage / 'var/jb/Applications/NetShield2.app/stray'
            misplaced.parent.mkdir(parents=True)
            misplaced.write_bytes(b'wrong prefix')
            run('validate.py', *arguments, error='Unexpected package file: var/jb/')
            misplaced.unlink()
            if os.name == 'posix':
                (debian / 'postinst').chmod(0o644)
                run('validate.py', *arguments, error='Maintainer script must be executable')
                (debian / 'postinst').chmod(0o755)
                (app / 'NetShield2').chmod(0o644)
                run('validate.py', *arguments, error='Missing executable permissions')
                (app / 'NetShield2').chmod(0o755)
            run('validate.py', *arguments)

        for name, source in sources.items():
            assert (ROOT / 'layout/DEBIAN' / name).read_bytes() == source
        print(f'Passed {scheme} package layout, metadata and script checks')

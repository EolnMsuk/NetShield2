"""Check packaging CLIs with staged fixtures, including invalid rootful packages."""
import os
import pathlib
import plistlib
import shutil
import shlex
import struct
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
import sync_version
from sync_version import generate_bundle_metadata, release_metadata
from prepare_package import maintainer_script


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


def check_generated_metadata(temporary):
    fixture = temporary / 'metadata'
    fixture.mkdir()
    (fixture / 'Shared').mkdir()
    shutil.copyfile(ROOT / 'control', fixture / 'control')
    shutil.copyfile(ROOT / 'Shared/NSConstants.h', fixture / 'Shared/NSConstants.h')
    templates = [ROOT / source / 'Resources/Info.plist' for source, _, _ in BUNDLES]
    originals = [path.read_bytes() for path in templates]
    output = [fixture / source / 'Info.plist' for source, _, _ in BUNDLES]
    previous_root = sync_version.ROOT
    try:
        sync_version.ROOT = fixture
        for version in (release_metadata()['Version'], '9.8.7'):
            control = fixture / 'control'
            control.write_text(control.read_text().replace(
                'Version: ' + release_metadata()['Version'], 'Version: ' + version), newline='\n')
            # Exercise independent bundle outputs and racing atomic writes to one output.
            with ThreadPoolExecutor(max_workers=6) as workers:
                futures = [workers.submit(generate_bundle_metadata, template, path)
                           for template, path in zip(templates, output) for _ in range(2)]
                for future in futures:
                    future.result()
            for template, path, original in zip(templates, output, originals):
                info = plistlib.loads(path.read_bytes())
                assert info['CFBundleShortVersionString'] == version
                assert info['CFBundleVersion'] == sync_version.bundle_build_version()
                assert {k: v for k, v in info.items() if k not in (
                    'CFBundleVersion', 'CFBundleShortVersionString')} == plistlib.loads(original)
                assert template.read_bytes() == original
                if os.name == 'posix':
                    assert path.stat().st_mode & 0o777 == 0o644
                modified = path.stat().st_mtime_ns
                generate_bundle_metadata(template, path)
                assert path.stat().st_mtime_ns == modified
        try:
            generate_bundle_metadata(templates[0], templates[0])
        except ValueError:
            pass
        else:
            raise AssertionError('Generator must reject writing to the source template')
    finally:
        sync_version.ROOT = previous_root
    run('sync_version.py')
    assert [path.read_bytes() for path in templates] == originals
    print('Passed generated metadata, release changes, atomic writes and source preservation')


def check_install_lifecycle(temporary, scheme):
    shell = shutil.which('sh')
    if not shell:
        print(f'Skipped {scheme} postinst execution: POSIX sh unavailable (macOS CI required)')
        return
    prefix = '/var/jb' if scheme == 'rootless' else ''
    fixture = temporary / ('postinst-' + scheme)
    fixture.mkdir()
    log = fixture / 'calls'
    commands = {
        'uicache': 'printf "cache:%s\\n" "$*" >> "$TEST_LOG"\nexit "$CACHE_STATUS"\n',
        'dpkg-query': 'printf "query:%s\\n" "$*" >> "$TEST_LOG"\nprintf "%s" "$PACKAGE_STATUS"\n',
        'sbreload': 'printf "reload\\n" >> "$TEST_LOG"\nexit "$RELOAD_STATUS"\n',
    }
    source = maintainer_script(sources['postinst'], scheme).decode()
    for command, body in commands.items():
        path = fixture / command
        path.write_text('#!/bin/sh\n' + body, newline='\n')
        path.chmod(0o755)
        source = source.replace(f'{prefix}/usr/bin/{command}', shlex.quote(str(path)))
    legacy = fixture / 'legacy.app'
    legacy.mkdir()
    source = source.replace(f'{prefix}/Applications/NetShield.app', shlex.quote(str(legacy)))
    # Stub only process liveness, waiting and logging; all production control flow runs.
    source = source.replace('set -eu\n', '''set -eu
wait_checks=0
kill() {
    wait_checks=$((wait_checks + 1))
    printf 'wait\\n' >> "$TEST_LOG"
    [ "$WAIT_FOREVER" = 1 ] || [ "$wait_checks" -lt 3 ]
}
sleep() {
    if [ "$HOLD_WORKER" = 1 ]; then
        while [ ! -f "$RELEASE_WORKER" ]; do command sleep 0.01; done
    fi
}
logger() { printf 'diagnostic:%s\\n' "$*" >> "$TEST_LOG"; }
''')
    script = fixture / 'postinst'
    script.write_text(source, newline='\n')
    subprocess.run([shell, '-n', str(script)], check=True)
    version = release_metadata()['Version']
    cases = [
        (['configure'], 0, 0, 'install ok installed', False, True),
        (['configure', '1.0.0'], 0, 0, 'install ok installed', False, True),
        (['configure', version], 0, 0, 'install ok installed', False, True),
        (['configure'], 1, 0, 'install ok installed', False, False),
        (['configure'], 0, 0, 'install ok half-configured', False, False),
        (['configure'], 0, 1, 'install ok installed', False, True),
        (['configure'], 0, 0, 'install ok installed', True, False),
    ]
    cases += [([action], 0, 0, 'install ok installed', False, False)
              for action in ('abort-upgrade', 'abort-remove', 'abort-deconfigure', 'triggered', '')]
    release = fixture / 'release-worker'
    for index, (arguments, cache_status, reload_status, status, wait_forever, reload) in enumerate(cases):
        log.write_text('')
        environment = dict(os.environ, TEST_LOG=str(log), CACHE_STATUS=str(cache_status),
                           RELOAD_STATUS=str(reload_status), PACKAGE_STATUS=status,
                           WAIT_FOREVER=str(int(wait_forever)), HOLD_WORKER=str(int(index == 0)),
                           RELEASE_WORKER=str(release))
        # Captured pipes must close immediately even though the reload worker detaches.
        try:
            result = subprocess.run([shell, str(script), *arguments], env=environment,
                                    capture_output=True, text=True, timeout=5)
            if index == 0:
                assert 'reload' not in log.read_text().splitlines()
        finally:
            release.touch()
        assert result.returncode == cache_status, (arguments, result)
        worker = arguments[0] == 'configure' and not cache_status
        deadline = time.monotonic() + 3
        while worker and time.monotonic() < deadline:
            calls = log.read_text().splitlines()
            if any(call == 'reload' or call.startswith('diagnostic:') for call in calls):
                if not reload_status or any(call.startswith('diagnostic:') for call in calls):
                    break
            time.sleep(0.01)
        calls = log.read_text().splitlines()
        assert calls.count('reload') == int(reload), (arguments, calls)
        if worker:
            assert any(call.startswith('diagnostic:') for call in calls) == (
                wait_forever or reload_status != 0 or status != 'install ok installed'), calls
            if reload:
                assert calls.index('reload') > next(i for i, call in enumerate(calls)
                                                    if call.startswith('query:')), calls
                assert calls.count('wait') == 3, calls
        if arguments[0] != 'configure':
            assert calls == [], calls
    # Missing reload is diagnosed synchronously without a configure/retry loop.
    (fixture / 'sbreload').unlink()
    log.write_text('')
    result = subprocess.run([shell, str(script), 'configure'], env=environment,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0 and 'respring manually' in result.stderr
    assert 'reload' not in log.read_text().splitlines()
    print(f'Passed {scheme} fresh/update/reinstall, deferred reload, failure and non-configure checks')


with tempfile.TemporaryDirectory(prefix='netshield-packaging-') as directory:
    check_generated_metadata(pathlib.Path(directory))
    for scheme, architecture, prefix in VARIANTS:
        check_install_lifecycle(pathlib.Path(directory), scheme)
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
            generate_bundle_metadata(ROOT / source / 'Resources/Info.plist', bundle / 'Info.plist')
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
            if name == 'postinst':
                for command in ('sbreload', 'dpkg-query'):
                    assert f'/{prefix}usr/bin/{command}'.encode() in content
            if not prefix:
                assert b'/var/jb/' not in content
            else:
                assert content == sources[name]
        run('validate.py', *arguments)

        staged_info = app / 'Info.plist'
        original_info = staged_info.read_bytes()
        unresolved = plistlib.loads(original_info)
        unresolved['CFBundleShortVersionString'] = 'unresolved'
        staged_info.write_bytes(plistlib.dumps(unresolved))
        run('validate.py', *arguments, error='Bad staged metadata: NetShield2')
        staged_info.write_bytes(original_info)

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

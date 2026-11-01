"""Exercise prerm cleanup and detached respring using mock commands (POSIX host)."""
import argparse
import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile
import time
from prepare_package import PACKAGE_ARCHITECTURES, maintainer_script

parser = argparse.ArgumentParser()
parser.add_argument('--scheme', choices=PACKAGE_ARCHITECTURES, default='rootless')
args = parser.parse_args()
prefix = '/var/jb' if args.scheme == 'rootless' else ''

ROOT = pathlib.Path(__file__).resolve().parents[1]
shell = shutil.which("sh")
if not shell:
    raise SystemExit("Uninstall script tests require a POSIX sh (run on macOS CI).")

source = maintainer_script((ROOT / "layout/DEBIAN/prerm").read_bytes(), args.scheme).decode()
with tempfile.TemporaryDirectory(prefix="netshield-uninstall-") as directory:
    temporary = pathlib.Path(directory)
    log = temporary / "calls"
    app = temporary / "app"
    cache = temporary / "uicache"
    reload = temporary / "sbreload"
    app.write_text(
        '#!/bin/sh\nprintf "app:%s\\n" "$*" >> "$TEST_LOG"\n'
        'printf "%s\\n" "LYNX DEBUG startup noise"\n'
        'printf "%s\\n" "SnowBoard startup noise" >&2\n'
        'if [ "$APP_STATUS" != 0 ]; then\n'
        '    printf "%s\\n" "NetShield2: filter removal failed: mock error." >&2\n'
        'else\n'
        '    printf "%s\\n" "NetShield2: verified system filter is removed."\n'
        'fi\nexit "$APP_STATUS"\n')
    cache.write_text(
        '#!/bin/sh\nprintf "cache:%s\\n" "$*" >> "$TEST_LOG"\n'
        'printf "%s\\n" "Icon cache noise"\n'
        'printf "%s\\n" "Icon cache stderr noise" >&2\nexit "$CACHE_STATUS"\n')
    reload.write_text('#!/bin/sh\nprintf "reload\\n" >> "$TEST_LOG"\nexit "$RELOAD_STATUS"\n')
    app.chmod(0o755)
    cache.chmod(0o755)
    reload.chmod(0o755)
    script = temporary / "prerm"
    # Only liveness, waiting and diagnostics are stubbed; run the real worker.
    worker_stubs = '''set -eu
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
'''
    script.write_text(source.replace(f"{prefix}/Applications/NetShield2.app/NetShield2", shlex.quote(str(app)))
                     .replace(f"{prefix}/usr/bin/uicache", shlex.quote(str(cache)))
                     .replace(f"{prefix}/usr/bin/sbreload", shlex.quote(str(reload)))
                     .replace("set -eu\n", worker_stubs), newline='\n')
    subprocess.run([shell, "-n", str(script)], check=True)
    cases = [
        ("remove", 0, 0, 0, False),
        ("deconfigure", 0, 0, 0, False),
        ("remove", 1, 0, 0, False),
        ("remove", 137, 0, 0, False),
        ("deconfigure", 1, 0, 0, False),
        ("remove", 0, 1, 0, False),
        ("remove", 0, 0, 1, False),
        ("remove", 0, 0, 0, True),
    ]
    cases += [(action, 0, 0, 0, False) for action in (
        'upgrade', 'failed-upgrade', 'abort-upgrade', 'abort-remove', 'abort-deconfigure', '')]
    release = temporary / 'release-worker'
    for index, (action, app_status, cache_status, reload_status, wait_forever) in enumerate(cases):
        log.write_text("")
        environment = dict(os.environ, TEST_LOG=str(log), APP_STATUS=str(app_status),
                           CACHE_STATUS=str(cache_status), RELOAD_STATUS=str(reload_status),
                           WAIT_FOREVER=str(int(wait_forever)), HOLD_WORKER=str(int(index == 0)),
                           RELEASE_WORKER=str(release))
        # Completion with captured pipes proves the worker detached its descriptors.
        try:
            result = subprocess.run([shell, str(script), action], env=environment,
                                    capture_output=True, text=True, timeout=5)
            if index == 0:
                assert 'reload' not in log.read_text().splitlines()
        finally:
            release.touch()
        cleanup = action in ('remove', 'deconfigure')
        worker = action == 'remove' and not app_status and not cache_status
        diagnostic = cleanup and not app_status and (cache_status or (worker and (wait_forever or reload_status)))
        deadline = time.monotonic() + 3
        calls = log.read_text().splitlines()
        while worker and time.monotonic() < deadline:
            if (diagnostic and any(call.startswith('diagnostic:') for call in calls)) or (
                    not diagnostic and 'reload' in calls):
                break
            time.sleep(0.01)
            calls = log.read_text().splitlines()
        expected_status = int(cleanup and app_status != 0)
        assert result.returncode == expected_status, (action, result.stderr)
        operations = [call for call in calls if call != 'wait' and not call.startswith('diagnostic:')]
        expected = ['app:--remove-filter'] if cleanup else []
        if cleanup and not app_status:
            expected.append(f'cache:-u {prefix}/Applications/NetShield2.app')
        if worker and not wait_forever:
            expected.append('reload')
        assert operations == expected, (action, calls)
        assert any(call.startswith('diagnostic:') for call in calls) == bool(diagnostic), calls
        assert calls.count('wait') == (601 if wait_forever else 3) * int(worker), calls
        if worker:
            assert calls.index('wait') > calls.index(expected[1]), calls
        assert result.stdout == "", (action, result.stdout)
        assert "LYNX" not in result.stderr and "SnowBoard" not in result.stderr
        assert "Icon cache" not in result.stderr
        if expected_status:
            assert "Remove Filter & Settings" in result.stderr
            assert "NetShield2: filter removal failed: mock error." in result.stderr
            assert f"exit {app_status}" in result.stderr
        else:
            assert result.stderr == "", (action, result.stderr)
    reload.unlink()
    log.write_text('')
    result = subprocess.run([shell, str(script), 'remove'], env=environment,
                            capture_output=True, text=True, timeout=5)
    calls = log.read_text().splitlines()
    assert result.returncode == 0 and result.stdout == result.stderr == ''
    assert any('sbreload is unavailable' in call for call in calls), calls
    assert 'reload' not in calls and 'wait' not in calls, calls
    app.unlink()
    log.write_text("")
    result = subprocess.run([shell, str(script), "remove"], env=environment,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode != 0 and not log.read_text(), "Missing helper must stop removal"
    assert result.stdout == "" and "filter cleanup failed" in result.stderr
    assert "Remove Filter & Settings" in result.stderr
print(f"Passed {args.scheme} uninstall cleanup, deferred respring, timeout, missing tools and upgrade/abort checks")

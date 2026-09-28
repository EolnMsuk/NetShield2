"""Exercise the real prerm script with mock app/uicache commands (POSIX host)."""
import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
shell = shutil.which("sh")
if not shell:
    raise SystemExit("Uninstall script tests require a POSIX sh (run on macOS CI).")

source = (ROOT / "layout/DEBIAN/prerm").read_text()
with tempfile.TemporaryDirectory(prefix="netshield-uninstall-") as directory:
    temporary = pathlib.Path(directory)
    log = temporary / "calls"
    app = temporary / "app"
    cache = temporary / "uicache"
    app.write_text('#!/bin/sh\nprintf "app:%s\\n" "$*" >> "$TEST_LOG"\nexit "$APP_STATUS"\n')
    cache.write_text('#!/bin/sh\nprintf "cache:%s\\n" "$*" >> "$TEST_LOG"\nexit "$CACHE_STATUS"\n')
    app.chmod(0o755)
    cache.chmod(0o755)
    script = temporary / "prerm"
    script.write_text(source.replace("/var/jb/Applications/NetShield2.app/NetShield2", shlex.quote(str(app)))
                     .replace("/var/jb/usr/bin/uicache", shlex.quote(str(cache))))
    subprocess.run([shell, "-n", str(script)], check=True)
    for action, app_status, cache_status, expected_status, expected_calls in [
        ("remove", 0, 0, 0, 2),
        ("deconfigure", 0, 0, 0, 2),
        ("remove", 1, 0, 1, 1),
        ("deconfigure", 1, 0, 1, 1),
        ("remove", 0, 1, 0, 2),
        ("upgrade", 0, 0, 0, 0),
        ("failed-upgrade", 0, 0, 0, 0),
        ("", 0, 0, 0, 0),
    ]:
        log.write_text("")
        environment = dict(os.environ, TEST_LOG=str(log), APP_STATUS=str(app_status),
                           CACHE_STATUS=str(cache_status))
        result = subprocess.run([shell, str(script), action], env=environment,
                                capture_output=True, text=True, timeout=5)
        calls = log.read_text().splitlines()
        assert result.returncode == expected_status, (action, result.stderr)
        assert len(calls) == expected_calls, (action, calls)
        if calls:
            assert calls[0] == "app:--remove-filter", calls
        if expected_status:
            assert "Reset ALL Settings" in result.stderr
        if len(calls) == 2:
            assert calls[1] == "cache:-u /var/jb/Applications/NetShield2.app", calls
    app.unlink()
    log.write_text("")
    result = subprocess.run([shell, str(script), "remove"], env=environment,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode != 0 and not log.read_text(), "Missing helper must stop removal"
print("Passed uninstall hook checks: cleanup ordering, failures, missing helper and upgrade preservation")

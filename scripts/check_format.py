"""Check the Objective-C formatting without changing files."""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
formatter = sys.argv[1] if len(sys.argv) > 1 else "clang-format"
files = sorted(
    str(path.relative_to(ROOT))
    for directory in ("App", "Shared", "FilterData", "FilterControl", "Tests")
    for path in (ROOT / directory).iterdir()
    if path.suffix in (".m", ".h")
)
subprocess.run([formatter, "--dry-run", "--Werror", *files], cwd=ROOT, check=True)

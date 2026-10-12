"""Check the Objective-C formatting without changing files."""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG = ROOT / ".clang-format"
if not CONFIG.is_file():
    raise SystemExit(
        "Missing .clang-format at the repository root. Include this hidden file "
        "when copying or uploading the project; the default LLVM style is not "
        "the project's style."
    )

formatter = sys.argv[1] if len(sys.argv) > 1 else "clang-format"
files = sorted(
    str(path.relative_to(ROOT))
    for directory in ("App", "Shared", "FilterData", "FilterControl", "Tests")
    for path in (ROOT / directory).iterdir()
    if path.suffix in (".m", ".h")
)
result = subprocess.run(
    [formatter, f"--style=file:{CONFIG}", "--dry-run", "--Werror", *files],
    cwd=ROOT,
)
if result.returncode:
    raise SystemExit("Formatting check failed. Use clang-format 19.1.7 with the root .clang-format file.")

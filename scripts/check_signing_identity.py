"""Check the actual CodeDirectory identifier in a packaged executable on macOS."""
import pathlib
import plistlib
import subprocess
import sys


def check_identifier(output, expected):
    identifiers = [line.removeprefix('Identifier=') for line in output.splitlines()
                   if line.startswith('Identifier=')]
    if identifiers != [expected]:
        raise ValueError(f'Signing identifier mismatch: expected {expected!r}, got {identifiers!r}')


def main():
    executable = pathlib.Path(sys.argv[1])
    info = plistlib.loads((executable.parent / 'Info.plist').read_bytes())
    result = subprocess.run(['codesign', '--display', '--verbose=4', str(executable)],
                            capture_output=True, text=True, check=True)
    check_identifier(result.stdout + '\n' + result.stderr, info['CFBundleIdentifier'])
    print(f'Validated signing identifier for {executable.name}')


if __name__ == '__main__':
    main()

"""Check packaged CodeDirectory identifiers using the same verifier as CI."""
import argparse
import pathlib
from check_macho import inspect_file


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=pathlib.Path)
    executable = parser.parse_args().executable
    inspect_file(executable)
    print(f'Validated signing identifier for {executable.name}')


if __name__ == '__main__':
    main()

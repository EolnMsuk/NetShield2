"""Exercise the signing identifier CLI against embedded CodeDirectories."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from test_macho import executable


SCRIPTS = pathlib.Path(__file__).resolve().parent


def check_cli(expected, signed):
    with tempfile.TemporaryDirectory(prefix='identity-fixture-', dir=SCRIPTS.parent) as directory:
        bundle = pathlib.Path(directory)
        (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': expected}))
        binary = bundle / 'NetShield2'
        binary.write_bytes(executable(signed))
        return subprocess.run([sys.executable, str(SCRIPTS / 'check_signing_identity.py'), str(binary)],
                              capture_output=True, text=True, timeout=10)


class SigningIdentityTests(unittest.TestCase):
    def test_bundle_identifiers(self):
        for suffix in ('', '.data', '.control'):
            expected = 'com.eolnmsuk.netshield' + suffix
            with self.subTest(expected=expected):
                result = check_cli(expected, expected)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrong_or_temporary_identifier(self):
        for signed in ('', '.NetShield2.8fbaec11.unsigned', 'NetShield2', 'com.eolnmsuk.netshield.data'):
            with self.subTest(signed=signed):
                result = check_cli('com.eolnmsuk.netshield', signed)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('CodeDirectory identifier mismatch', result.stderr)


if __name__ == '__main__':
    unittest.main()

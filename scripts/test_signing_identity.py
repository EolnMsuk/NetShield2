"""Exercise signing identity validation, including the temporary-name regression."""
import unittest
from check_signing_identity import check_identifier


class SigningIdentityTests(unittest.TestCase):
    def test_bundle_identifiers(self):
        for suffix in ('', '.data', '.control'):
            expected = 'com.eolnmsuk.netshield' + suffix
            check_identifier(f'Executable=/some/path\nIdentifier={expected}\nFormat=Mach-O\n', expected)

    def test_missing_wrong_or_ambiguous_identifier(self):
        for output in ('', 'code object is not signed at all',
                       'Identifier=.NetShield2.8fbaec11.unsigned',
                       'Identifier=NetShield2', 'Identifier=com.eolnmsuk.netshield.data',
                       'Identifier=com.eolnmsuk.netshield\nIdentifier=other'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                check_identifier(output, 'com.eolnmsuk.netshield')


if __name__ == '__main__':
    unittest.main()

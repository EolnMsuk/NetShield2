"""Synthetic parser and signed-content tamper fixtures, not real package proof."""
import hashlib
import struct
import unittest
from check_macho import inspect


def executable():
    identity = b'com.eolnmsuk.netshield\0'
    entitlement = b'<?xml version="1.0"?><plist><dict/></plist>'
    entitlement = struct.pack('>II', 0xfade7171, 8 + len(entitlement)) + entitlement
    start_hashes = 44 + len(identity) + 5 * 32
    directory_size = start_hashes + 32
    signature_size = 28 + directory_size + len(entitlement)
    raw = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 2, 32, 0, 0)
    raw += struct.pack('<4I', 0x25, 16, 15 << 16, (16 << 16) | (5 << 8))
    raw += struct.pack('<4I', 0x1d, 16, 256, signature_size)
    raw += b'\0' * (256 - len(raw))
    directory = struct.pack('>9I4BI', 0xfade0c02, directory_size, 0x20100, 2,
                            start_hashes, 44, 5, 1, 256, 32, 2, 0, 12, 0)
    directory += identity + hashlib.sha256(entitlement).digest() + b'\0' * (4 * 32)
    directory += hashlib.sha256(raw).digest()
    signature = struct.pack('>7I', 0xfade0cc0, signature_size, 2, 0, 28,
                            5, 28 + len(directory))
    return raw + signature + directory + entitlement


class MachOTests(unittest.TestCase):
    def test_valid_content_and_entitlements(self):
        self.assertEqual(inspect(executable(), 'com.eolnmsuk.netshield')['minimum_os'], '15.0')

    def test_wrong_identifier(self):
        with self.assertRaisesRegex(ValueError, 'identifier mismatch'):
            inspect(executable(), 'wrong')

    def test_tampered_page(self):
        raw = bytearray(executable())
        raw[100] ^= 1
        with self.assertRaisesRegex(ValueError, 'signed code page'):
            inspect(raw, 'com.eolnmsuk.netshield')

    def test_tampered_entitlements(self):
        raw = bytearray(executable())
        raw[-1] ^= 1
        with self.assertRaisesRegex(ValueError, 'special slot 5'):
            inspect(raw, 'com.eolnmsuk.netshield')

    def test_truncation_and_malformed_commands(self):
        for size in (0, 12, 31, 63, 255, len(executable()) - 1):
            with self.subTest(size=size), self.assertRaises((ValueError, struct.error)):
                inspect(executable()[:size], 'com.eolnmsuk.netshield')
        for offset, value in ((0, 0), (4, 0x1000007), (8, 2), (36, 0),
                              (40, 14 << 16), (52, 8), (56, 9999999)):
            raw = bytearray(executable())
            struct.pack_into('<I', raw, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                inspect(raw, 'com.eolnmsuk.netshield')


if __name__ == '__main__':
    unittest.main()

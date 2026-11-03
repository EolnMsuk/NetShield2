"""Synthetic parser and signed-content tamper fixtures, not real package proof."""
import hashlib
import struct
import unittest
from check_macho import inspect


def executable(identifier='com.eolnmsuk.netshield', *, include_xml=True, include_der=False):
    identity = identifier.encode() + b'\0'
    entitlements = {}
    if include_xml:
        xml = b'<?xml version="1.0"?><plist><dict/></plist>'
        entitlements[5] = struct.pack('>II', 0xfade7171, 8 + len(xml)) + xml
    if include_der:
        entitlements[7] = struct.pack('>II', 0xfade7172, 10) + b'\x31\x00'
    special = max(entitlements, default=0)
    algorithms = ((1, 'sha1', 20), (2, 'sha256', 32))
    header_size = 88  # CodeDirectory v2.4
    table_size = 12 + 8 * (len(algorithms) + len(entitlements))
    signature_size = table_size + sum(len(blob) for blob in entitlements.values())
    signature_size += sum(header_size + len(identity) + (special + 1) * size for _, _, size in algorithms)
    raw = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 2, 32, 0, 0)
    raw += struct.pack('<4I', 0x25, 16, 15 << 16, (16 << 16) | (5 << 8))
    raw += struct.pack('<4I', 0x1d, 16, 256, signature_size)
    raw += b'\0' * (256 - len(raw))
    blobs = dict(entitlements)
    for slot, (hash_type, name, size) in zip((0, 0x1000), algorithms):
        start_hashes = header_size + len(identity) + special * size
        # ldid -S emits CodeDirectories without a CMS blob or the Apple ad hoc flag.
        directory = struct.pack('>9I4B4I4Q', 0xfade0c02, start_hashes + size, 0x20400, 0,
                                start_hashes, header_size, special, 1, 256, size, hash_type, 0, 12,
                                0, 0, 0, 0, 0, 0, 256, 1)
        directory += identity
        for index in range(special, 0, -1):
            blob = entitlements.get(index)
            directory += hashlib.new(name, blob).digest() if blob else bytes(size)
        blobs[slot] = directory + hashlib.new(name, raw).digest()
    signature = struct.pack('>III', 0xfade0cc0, signature_size, len(blobs))
    contents = bytearray()
    for slot, blob in sorted(blobs.items()):
        signature += struct.pack('>II', slot, table_size + len(contents))
        contents += blob
    return raw + signature + contents


def blob_offset(raw, slot):
    offset = struct.unpack_from('<I', raw, 56)[0]
    count = struct.unpack_from('>I', raw, offset + 8)[0]
    for index in range(count):
        kind, start = struct.unpack_from('>II', raw, offset + 12 + 8 * index)
        if kind == slot:
            return offset + start
    raise AssertionError(f'Fixture has no slot {slot}')


class MachOTests(unittest.TestCase):
    def test_valid_content_and_entitlements(self):
        for include_der in (False, True):
            result = inspect(executable(include_der=include_der), 'com.eolnmsuk.netshield')
            self.assertEqual(result['minimum_os'], '15.0')
            self.assertEqual(result['verified_code_directories'], 2)

    def test_wrong_identifier(self):
        with self.assertRaisesRegex(ValueError, 'identifier mismatch'):
            inspect(executable(), 'wrong')

    def test_tampered_page(self):
        raw = bytearray(executable())
        raw[100] ^= 1
        with self.assertRaisesRegex(ValueError, 'signed code page'):
            inspect(raw, 'com.eolnmsuk.netshield')

    def test_tampered_entitlements(self):
        for slot in (5, 7):
            raw = bytearray(executable(include_der=True))
            raw[blob_offset(raw, slot) + 8] ^= 1
            with self.subTest(slot=slot), self.assertRaisesRegex(ValueError, f'special slot {slot}'):
                inspect(raw, 'com.eolnmsuk.netshield')

    def test_entitlements_required_and_bound_in_each_directory(self):
        with self.assertRaisesRegex(ValueError, 'entitlement blob in slot 5'):
            inspect(executable(include_xml=False), 'com.eolnmsuk.netshield')
        for slot in (5, 7):
            raw = bytearray(executable(include_der=True))
            alternate = blob_offset(raw, 0x1000)
            hashes = alternate + struct.unpack_from('>I', raw, alternate + 16)[0]
            raw[hashes - slot * 32:hashes - (slot - 1) * 32] = bytes(32)
            with self.subTest(slot=slot), self.assertRaisesRegex(ValueError, f'Unbound.*slot {slot}'):
                inspect(raw, 'com.eolnmsuk.netshield')

    def test_primary_slot_and_alternate_identifier_required(self):
        raw = bytearray(executable())
        struct.pack_into('>I', raw, 256 + 12, 0x1001)
        with self.assertRaisesRegex(ValueError, 'Missing primary CodeDirectory'):
            inspect(raw, 'com.eolnmsuk.netshield')
        raw = bytearray(executable())
        alternate = blob_offset(raw, 0x1000)
        identity = alternate + struct.unpack_from('>I', raw, alternate + 20)[0]
        raw[identity] = ord('x')
        with self.assertRaisesRegex(ValueError, 'identifier mismatch'):
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

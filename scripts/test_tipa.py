"""Archive fixtures verify audit failures; they are not signed app/device tests."""
import pathlib
import plistlib
import struct
import tempfile
import unittest
import zipfile
from build_tipa import build
from check_tipa import APP, BUNDLES, audit_macho, check_archive
from sync_version import bundle_metadata, ROOT


def fixture_macho(dependency=b'/usr/lib/libSystem.B.dylib', cryptid=0, rpath=False):
    name = dependency + b'\0'
    length = (24 + len(name) + 7) // 8 * 8
    commands = [struct.pack('<6I', 0xc, length, 24, 0, 0, 0) + name +
                bytes(length - 24 - len(name)),
                struct.pack('<4I', 0x25, 16, 0xf0000, 0x100500),
                struct.pack('<6I', 0x2c, 24, 0, 0, cryptid, 0)]
    if rpath:
        commands.append(struct.pack('<4I', 0x8000001c, 16, 12, 0))
    size = sum(map(len, commands)) + 16
    commands.append(struct.pack('<4I', 0x1d, 16, 32 + size, 8))
    return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, len(commands), size, 0, 0) + \
        b''.join(commands) + bytes(8)


class ArchiveTests(unittest.TestCase):
    def test_macho_rejects_bootstrap_encryption_rpaths_and_malformed_commands(self):
        self.assertEqual(audit_macho(fixture_macho())['architecture'], 'arm64')
        for raw in (fixture_macho(b'/var/jb/usr/lib/test.dylib'),
                    fixture_macho(b'/usr/lib/libroothide.dylib'),
                    fixture_macho(b'/usr/lib/libhooker.dylib'),
                    fixture_macho(b'@rpath/external.framework/external'),
                    fixture_macho(cryptid=1), fixture_macho(rpath=True), fixture_macho()[:32]):
            with self.subTest(raw=raw[:32]), self.assertRaises(ValueError):
                audit_macho(raw)
        bad = bytearray(fixture_macho())
        struct.pack_into('<I', bad, 36, 0)
        with self.assertRaises(ValueError):
            audit_macho(bad)

    def test_deterministic_archive_identity_scope_and_exact_binary_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            app = temporary / 'NetShield2.app'
            for source, relative, executable in BUNDLES:
                bundle = app / relative
                bundle.mkdir(parents=True, exist_ok=True)
                (bundle / 'Info.plist').write_bytes(plistlib.dumps(
                    bundle_metadata(ROOT / source / 'Resources/Info.plist')))
                (bundle / executable).write_bytes(fixture_macho())
            output = temporary / 'one.tipa'
            build(app, output)
            other = temporary / 'two.tipa'
            build(app, other)
            self.assertEqual(output.read_bytes(), other.read_bytes())
            self.assertEqual(len(check_archive(output)), 3)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.read(APP + 'NetShield2'), fixture_macho())
            info = app / 'Info.plist'
            original = info.read_bytes()
            bad = plistlib.loads(original)
            bad['CFBundleIdentifier'] = 'wrong.owner'
            info.write_bytes(plistlib.dumps(bad))
            with self.assertRaises(ValueError):
                build(app, temporary / 'invalid.tipa')
            info.write_bytes(original)
            with zipfile.ZipFile(output, 'a') as archive:
                archive.writestr('../outside', b'bad')
            with self.assertRaises(ValueError):
                check_archive(output)
            (app / 'unexpected.dylib').write_bytes(fixture_macho())
            with self.assertRaises(ValueError):
                build(app, temporary / 'invalid.tipa')


if __name__ == '__main__':
    unittest.main()

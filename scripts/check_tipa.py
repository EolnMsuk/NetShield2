"""Audit the plain Phase 0 archive. Real signing checks also run in macOS CI."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import stat
import struct
import zipfile
from sync_version import bundle_metadata

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = 'Payload/NetShield2.app/'
BUNDLES = (
    ('App', '', 'NetShield2'),
    ('FilterData', 'PlugIns/NetShield2Data.appex/', 'NetShield2Data'),
    ('FilterControl', 'PlugIns/NetShield2Control.appex/', 'NetShield2Control'),
)
FORBIDDEN = (b'/var/jb', b'.jbroot', b'libroothide', b'roothideinit', b'libvroot',
             b'libroot.', b'substrate', b'ellekit', b'/bootstrap/')
SYSTEM_LIBRARIES = {b'/usr/lib/libSystem.B.dylib', b'/usr/lib/libobjc.A.dylib',
                    b'/usr/lib/libc++.1.dylib', b'/usr/lib/libc++abi.dylib'}


def require(value, message):
    if not value:
        raise ValueError(message)


def audit_macho(raw):
    require(len(raw) >= 32, 'Truncated Mach-O')
    magic, cpu, subtype, filetype, ncmds, size, _, _ = struct.unpack_from('<8I', raw)
    require(magic == 0xfeedfacf and cpu == 0x100000c and subtype == 0,
            'Expected thin arm64 (not arm64e) Mach-O')
    require(filetype == 2, 'Expected an executable Mach-O')
    require(32 + size <= len(raw), 'Load commands exceed file')
    cursor = 32
    dependencies = []
    signed = False
    platform_seen = False
    for _ in range(ncmds):
        require(cursor + 8 <= 32 + size, 'Truncated load command')
        command, length = struct.unpack_from('<II', raw, cursor)
        require(length >= 8 and length % 8 == 0 and cursor + length <= 32 + size,
                'Invalid load command length')
        payload = raw[cursor:cursor + length]
        # LC_LOAD_DYLIB, weak/reexport/upward dylibs; system frameworks/libs only.
        if command in (0xc, 0x80000018, 0x8000001f, 0x80000023):
            require(length >= 24, 'Truncated dylib command')
            offset = struct.unpack_from('<I', payload, 8)[0]
            require(24 <= offset < length and b'\0' in payload[offset:], 'Invalid dylib name')
            name = payload[offset:].split(b'\0', 1)[0]
            require(name.startswith(b'/System/Library/Frameworks/') or name in SYSTEM_LIBRARIES,
                    f'Non-system dependency: {name!r}')
            require(not any(word in name.lower() for word in FORBIDDEN),
                    f'Jailbreak dependency: {name!r}')
            dependencies.append(name.decode())
        require(command != 0x8000001c, 'Rpaths are not allowed in the plain PoC')
        require(command != 0x27, 'Dyld environment injection is forbidden')
        if command == 0xe:  # LC_LOAD_DYLINKER
            require(length >= 16, 'Truncated dynamic linker command')
            offset = struct.unpack_from('<I', payload, 8)[0]
            require(12 <= offset < length and payload[offset:].split(b'\0', 1)[0] == b'/usr/lib/dyld',
                    'Unexpected dynamic linker')
        require(not any(word in payload.lower() for word in FORBIDDEN),
                'Bootstrap reference in load command')
        if command == 0x19:  # LC_SEGMENT_64
            require(length >= 72, 'Truncated segment')
            sections = struct.unpack_from('<I', payload, 64)[0]
            require(72 + sections * 80 <= length, 'Truncated sections')
            for index in range(sections):
                section = payload[72 + index * 80:72 + (index + 1) * 80]
                section_name = section[:16].split(b'\0', 1)[0]
                section_size = struct.unpack_from('<Q', section, 40)[0]
                require(not (section_name == b'__mod_init_func' and section_size),
                        'Startup constructor requires manual audit; refusing plain PoC')
        if command == 0x1d:  # LC_CODE_SIGNATURE
            require(length >= 16, 'Truncated signature command')
            start, count = struct.unpack_from('<II', payload, 8)
            require(count > 0 and start >= 32 + size and start + count <= len(raw),
                    'Invalid code-signature extent')
            signed = True
        if command == 0x2c:  # LC_ENCRYPTION_INFO_64
            require(length >= 24 and struct.unpack_from('<I', payload, 16)[0] == 0,
                    'Encrypted executable')
        if command in (0x25, 0x32):  # LC_VERSION_MIN_IPHONEOS / LC_BUILD_VERSION
            require(length >= (16 if command == 0x25 else 24), 'Truncated OS command')
            if command == 0x32:
                require(struct.unpack_from('<I', payload, 8)[0] == 2, 'Expected iOS platform')
            minimum = struct.unpack_from('<I', payload, 8 if command == 0x25 else 12)[0]
            require(minimum == 0xf0000, 'Expected iOS 15.0 deployment target')
            platform_seen = True
        cursor += length
    require(cursor == 32 + size and signed and platform_seen and dependencies,
            'Missing load commands, signing, iOS version or system dependencies')
    return {'dependencies': dependencies, 'architecture': 'arm64', 'minimumOS': '15.0'}


def audit_files(files):
    expected = {APP + path + executable for _, path, executable in BUNDLES}
    found = set()
    report = {}
    require(all(name.startswith(APP) and '..' not in pathlib.PurePosixPath(name).parts and
                '\\' not in name and '.jbroot' not in name for name in files), 'Unexpected archive path')
    allowed_bundles = {'NetShield2.app', 'NetShield2Data.appex', 'NetShield2Control.appex'}
    require(all(not any(part.endswith(('.app', '.appex', '.framework', '.xpc')) and
                        part not in allowed_bundles for part in pathlib.PurePosixPath(name).parts)
                for name in files), 'Unexpected nested bundle')
    for directory, path, executable in BUNDLES:
        prefix = APP + path
        require(prefix + 'Info.plist' in files, f'Missing metadata: {executable}')
        require(plistlib.loads(files[prefix + 'Info.plist']) ==
                bundle_metadata(ROOT / directory / 'Resources/Info.plist'),
                f'Unexpected identity/version metadata: {executable}')
        require(prefix + executable in files, f'Missing executable: {executable}')
    for name, raw in files.items():
        require(not name.endswith(('.dylib', '.deb', '.tipa')), 'Unexpected embedded code/archive')
        if raw[:4] in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe',
                       b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                       b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
            require(name in expected, f'Unexpected Mach-O: {name}')
            found.add(name)
            report[name] = audit_macho(raw)
    require(found == expected, 'Expected exactly the app and both provider binaries')
    return report


def check_archive(path):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        require(len(names) == len(set(names)), 'Duplicate archive entries')
        for entry in entries:
            require(entry.filename.startswith(APP) and
                    '..' not in pathlib.PurePosixPath(entry.filename).parts and
                    '\\' not in entry.filename, 'Unexpected archive path')
            mode = entry.external_attr >> 16
            require(not stat.S_ISLNK(mode), 'Archive symlinks are forbidden')
            if entry.filename in {APP + p + e for _, p, e in BUNDLES}:
                require(mode & 0o111 == 0o111, 'Executable permission missing')
        files = {entry.filename: archive.read(entry) for entry in entries if not entry.is_dir()}
    return audit_files(files)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=pathlib.Path)
    args = parser.parse_args()
    print(json.dumps({'sha256': hashlib.sha256(args.archive.read_bytes()).hexdigest(),
                      'audit': check_archive(args.archive)}, indent=2))

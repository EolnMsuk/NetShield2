"""Inspect real thin arm64 iOS executables and verify embedded code-page hashes.

This verifies content integrity, not Apple trust or jailbreak acceptance. The
workflow also invokes codesign and checks signed identifiers and entitlements.
"""
import argparse
import hashlib
import pathlib
import plistlib
import struct


def require(value, message):
    if not value:
        raise ValueError(message)


def cstring(data, offset, end):
    require(0 <= offset < end <= len(data), 'Invalid string offset')
    stop = data.find(b'\0', offset, end)
    require(stop >= 0, 'Unterminated load-command string')
    return data[offset:stop].decode('utf-8', errors='strict')


def verify_signature(raw, offset, size, identifier, special_files):
    require(size >= 12 and offset + size == len(raw), 'Invalid signature extent')
    signature = raw[offset:offset + size]
    magic, length, count = struct.unpack_from('>III', signature)
    require(magic == 0xfade0cc0 and 12 + 8 * count <= length <= size,
            'Invalid embedded signature')
    require(not any(signature[length:]), 'Nonzero signature padding')
    blobs = {}
    ranges = []
    for index in range(count):
        kind, start = struct.unpack_from('>II', signature, 12 + 8 * index)
        require(kind not in blobs and 12 + 8 * count <= start <= length - 8,
                'Invalid or duplicate signature blob')
        blob_magic, blob_size = struct.unpack_from('>II', signature, start)
        require(blob_size >= 8 and start + blob_size <= length, 'Truncated signature blob')
        require(all(start >= right or start + blob_size <= left for left, right in ranges),
                'Overlapping signature blobs')
        ranges.append((start, start + blob_size))
        blobs[kind] = (blob_magic, signature[start:start + blob_size])
    directories = [blob for magic, blob in blobs.values() if magic == 0xfade0c02]
    require(directories, 'Missing CodeDirectory')
    algorithms = {1: ('sha1', 20), 2: ('sha256', 32), 3: ('sha256', 20), 4: ('sha384', 48)}
    for directory in directories:
        require(len(directory) >= 44, 'Truncated CodeDirectory')
        _, _, version, flags, hashes, ident, special, slots, limit = struct.unpack_from('>9I', directory)
        hash_size, hash_type, platform, page = struct.unpack_from('4B', directory, 36)
        require(hash_type in algorithms and hash_size == algorithms[hash_type][1],
                'Unsupported CodeDirectory hash')
        require(10 <= page <= 20 and 0 < limit == offset, 'Invalid code-page limit')
        require(slots == (limit + (1 << page) - 1) >> page, 'Code-slot count mismatch')
        require(special <= 64 and hashes - special * hash_size >= 44 and
                hashes + slots * hash_size <= len(directory), 'Invalid hash table')
        require(cstring(directory, ident, hashes - special * hash_size) == identifier,
                'CodeDirectory identifier mismatch')
        algorithm = algorithms[hash_type][0]
        digest = lambda data: hashlib.new(algorithm, data).digest()[:hash_size]
        for slot in range(slots):
            expected = directory[hashes + slot * hash_size:hashes + (slot + 1) * hash_size]
            require(expected == digest(raw[slot << page:min((slot + 1) << page, limit)]),
                    f'Invalid signed code page {slot}')
        for slot in range(1, special + 1):
            expected = directory[hashes - slot * hash_size:hashes - (slot - 1) * hash_size]
            if not any(expected):
                continue
            value = special_files.get(slot)
            if slot in blobs:
                value = blobs[slot][1]
            require(value is not None and digest(value) == expected,
                    f'Invalid or unavailable signed special slot {slot}')
    return len(directories)


def inspect(raw, identifier, special_files=None):
    require(32 <= len(raw) <= 128 * 1024 * 1024, 'Invalid executable size')
    magic, cpu, subtype, filetype, count, command_size, flags, reserved = struct.unpack_from('<8I', raw)
    require(magic == 0xfeedfacf and cpu == 0x100000c and subtype & 0xffffff == 0,
            'Expected thin arm64 (not arm64e or simulator)')
    require(filetype == 2 and 0 < count <= command_size // 8 and 32 + command_size <= len(raw),
            'Invalid executable load commands')
    cursor = 32
    minimums, signatures, dependencies = [], [], []
    for _ in range(count):
        require(cursor + 8 <= 32 + command_size, 'Truncated load command')
        command, size = struct.unpack_from('<II', raw, cursor)
        require(size >= 8 and size % 8 == 0 and cursor + size <= 32 + command_size,
                'Invalid load-command size')
        kind = command & 0x7fffffff
        if kind == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, 'Truncated build version')
            platform, minimum, sdk, tools = struct.unpack_from('<4I', raw, cursor + 8)
            require(platform == 2 and 24 + tools * 8 == size, 'Expected iOS device platform')
            minimums.append(minimum)
        elif kind == 0x25:  # LC_VERSION_MIN_IPHONEOS
            require(size == 16, 'Invalid minimum-OS command')
            minimums.append(struct.unpack_from('<I', raw, cursor + 8)[0])
        elif kind == 0x1d:  # LC_CODE_SIGNATURE
            require(size == 16, 'Invalid signature command')
            signatures.append(struct.unpack_from('<II', raw, cursor + 8))
        elif kind in (0xc, 0x18, 0x1f, 0x20, 0x23):
            require(size >= 24, 'Truncated dependency command')
            name_offset = struct.unpack_from('<I', raw, cursor + 8)[0]
            require(name_offset >= 24, 'Invalid dependency string')
            name = cstring(raw, cursor + name_offset, cursor + size)
            require(name.startswith(('/System/Library/', '/usr/lib/', '/var/jb/usr/lib/')) and
                    '..' not in name.split('/') and
                    not any(word in name.lower() for word in ('substrate', 'substitute', 'ellekit')),
                    f'Unexpected dependency: {name}')
            dependencies.append(name)
        cursor += size
    require(cursor == 32 + command_size, 'Load-command count/size mismatch')
    require(minimums == [15 << 16], 'Expected one iOS 15.0 deployment declaration')
    require(len(signatures) == 1 and signatures[0][0] >= cursor, 'Missing/duplicate signature')
    directories = verify_signature(raw, *signatures[0], identifier, special_files or {})
    return {'architecture': 'arm64', 'minimum_os': '15.0', 'dependencies': dependencies,
            'verified_code_directories': directories}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=pathlib.Path)
    args = parser.parse_args()
    bundle = args.executable.parent
    info_bytes = (bundle / 'Info.plist').read_bytes()
    special = {1: info_bytes}
    resources = bundle / '_CodeSignature/CodeResources'
    if resources.is_file():
        special[3] = resources.read_bytes()
    result = inspect(args.executable.read_bytes(), plistlib.loads(info_bytes)['CFBundleIdentifier'], special)
    print(f'Validated Mach-O and embedded content hashes: {args.executable.name}: {result}')


if __name__ == '__main__':
    main()

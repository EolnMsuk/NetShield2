"""Validate source metadata or the staged deb tree; does not emulate iOS."""
import argparse
import pathlib
import plistlib
import re
import struct

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--stage', type=pathlib.Path)
args = parser.parse_args()

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def plist(path):
    return plistlib.loads(path.read_bytes())

control = (ROOT / 'control').read_bytes()
require(b'\r' not in control, 'control must have LF line endings')
metadata = dict(line.split(': ', 1) for line in control.decode().splitlines() if ': ' in line)
require(metadata['Version'] == '2.0.0', 'Wrong package version')
require(metadata['Architecture'] == 'iphoneos-arm64', 'Wrong rootless architecture')
require(metadata.get('Icon') == 'file:///var/jb/Applications/NetShield.app/Icon.png', 'Missing package icon')
require((ROOT / 'App/Resources/Icon.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid app icon')
require('mobilesubstrate' not in metadata['Depends'], 'v1 injection dependency remains')

bundles = [
    ('App', 'NetShield', '', None, None),
    ('FilterData', 'NetShieldData', '.data', 'com.apple.networkextension.filter-data', 'NSFilterDataProvider'),
    ('FilterControl', 'NetShieldControl', '.control', 'com.apple.networkextension.filter-control', 'NSFilterControlProvider'),
]
for directory, binary, suffix, point, principal in bundles:
    source = ROOT / directory
    info = plist(source / 'Resources/Info.plist')
    require(info['CFBundleIdentifier'] == 'com.eolnmsuk.netshield' + suffix, 'Bundle ID mismatch')
    require(info['CFBundleExecutable'] == binary, 'Executable mismatch')
    require(info['MinimumOSVersion'] == '16.0', 'Deployment mismatch')
    require(info.get('CFBundleVersion') == '20010',
            f'{directory}/Resources/Info.plist: CFBundleVersion is '
            f'{info.get("CFBundleVersion")!r}; expected "20010" for {metadata["Version"]}. '
            'Upload all three release Info.plist files and start a new workflow run on that commit.')
    if point:
        require(info['NSExtension'] == dict(NSExtensionPointIdentifier=point, NSExtensionPrincipalClass=principal), 'Bad extension registration metadata')
    ent = plist(source / 'Entitlements.plist')
    require(ent['application-identifier'] == info['CFBundleIdentifier'], 'Entitlement identity mismatch')
    if directory == 'App':
        require(info.get('SBAppUsesLocalNotifications') is True, 'Missing system-app notification registration flag')
        require(ent.get('get-task-allow') is True, 'Deployment requires the existing configuration entitlement')
    require(ent['com.apple.developer.networking.networkextension'] == ['content-filter-provider'], 'Missing NE entitlement')
    require(ent['com.apple.security.application-groups'] == ['group.com.eolnmsuk.netshield'], 'App group mismatch')
    require('com.apple.private.security.no-sandbox' not in ent, 'Do not remove provider isolation')
    make = (source / 'Makefile').read_text()
    files = re.search(rf'^{binary}_FILES = (.+)$', make, re.M)
    require(files is not None, 'Missing source list')
    for name in files.group(1).split():
        require((source / name).is_file(), f'Missing {directory}/{name}')

for script in (ROOT / 'layout/DEBIAN').iterdir():
    raw = script.read_bytes()
    require(raw.startswith(b'#!/bin/sh\n') and b'\r' not in raw, f'{script.name}: invalid shell line endings')
for old in ('Sources', 'Preferences', 'NetShield.plist', 'projectstructure.md'):
    require(not (ROOT / old).exists(), f'Obsolete v1 input remains: {old}')

if args.stage:
    app = args.stage / 'var/jb/Applications/NetShield.app'
    for directory, binary, suffix, point, principal in bundles:
        bundle = app if directory == 'App' else app / f'PlugIns/{binary}.appex'
        require(plist(bundle / 'Info.plist') == plist(ROOT / directory / 'Resources/Info.plist'), f'Bad staged metadata: {binary}')
        executable = bundle / binary
        require(executable.is_file(), f'Missing executable {executable}')
        raw = executable.read_bytes()
        require(len(raw) >= 12, f'Truncated executable {binary}')
        magic, cputype = struct.unpack_from('<II', raw)
        require(magic == 0xfeedfacf and cputype == 0x100000c, f'Expected arm64 Mach-O: {binary}')
    require(not list(args.stage.rglob('*.dylib')), 'Unexpected injected library in package')
    allowed = {'var/jb/Applications/NetShield.app', 'DEBIAN'}
    for file in args.stage.rglob('*'):
        if file.is_file():
            relative = file.relative_to(args.stage).as_posix()
            require(any(relative.startswith(prefix + '/') for prefix in allowed), f'Unexpected package file: {relative}')
    print('Validated rootless app, embedded providers, arm64 binaries and package scope')
else:
    print('Validated v2 metadata, source paths, entitlements, scripts and v1 cleanup')

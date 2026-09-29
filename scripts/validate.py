import argparse
import json
import pathlib
import plistlib
import re
import struct
from urllib.parse import urlsplit

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
require(metadata['Version'] == '2.1.1', 'Wrong package version')
require(metadata['Name'] == 'NetShield2', 'Wrong product name')
require(metadata['Architecture'] == 'iphoneos-arm64', 'Wrong rootless architecture')
require(metadata['Depends'] == 'firmware (>= 15.0), firmware (<< 19.0), uikittools', 'Expected iOS 15-18 package range')
require(re.search(r'^export TARGET = iphone:clang:[^:]+:15\.0$', (ROOT / 'Makefile').read_text(), re.M), 'Expected iOS 15.0 deployment target')
require(metadata.get('Icon') == 'https://raw.githubusercontent.com/EolnMsuk/NetShield2/HEAD/App/Resources/Icon.png', 'Expected hosted package icon URL')
require((ROOT / 'App/Resources/Icon.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid app icon')
require('mobilesubstrate' not in metadata['Depends'], 'v1 injection dependency remains')

depiction = json.loads((ROOT / 'depiction.json').read_text())
require(metadata.get('SileoDepiction') == 'https://raw.githubusercontent.com/EolnMsuk/NetShield2/HEAD/depiction.json', 'Missing Sileo depiction')
require(metadata.get('Depiction') == 'https://github.com/EolnMsuk/NetShield2/#readme', 'Missing web depiction fallback')
require(depiction.get('class') == 'DepictionTabView' and depiction.get('minVersion') == '0.4', 'Invalid native depiction root')
banner_url = urlsplit(depiction.get('headerImage', ''))
banner_paths = {
    f'/EolnMsuk/NetShield2/{ref}/App/Resources/banner.png'
    for ref in ('HEAD', 'main', 'refs/heads/main')
}
require(banner_url.scheme == 'https' and
        banner_url.netloc == 'raw.githubusercontent.com' and
        banner_url.path in banner_paths,
        'Expected a raw GitHub banner.png URL for NetShield2 on HEAD or main; '
        'use https://raw.githubusercontent.com/EolnMsuk/NetShield2/main/App/Resources/banner.png')
require((ROOT / 'App/Resources/banner.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid package banner')


engine_version = re.search(r'NSEngineVersion\s*=\s*(\d+)', (ROOT / 'Shared/NSConstants.h').read_text()).group(1)
bundles = [
    ('App', 'NetShield2', '', None, None),
    ('FilterData', 'NetShield2Data', '.data', 'com.apple.networkextension.filter-data', 'NSFilterDataProvider'),
    ('FilterControl', 'NetShield2Control', '.control', 'com.apple.networkextension.filter-control', 'NSFilterControlProvider'),
]
for directory, binary, suffix, point, principal in bundles:
    source = ROOT / directory
    info = plist(source / 'Resources/Info.plist')
    require(info['CFBundleDisplayName'] == 'NetShield2', 'Wrong display name')
    require(info['CFBundleIdentifier'] == 'com.eolnmsuk.netshield' + suffix, 'Bundle ID mismatch')
    require(info['CFBundleExecutable'] == binary, 'Executable mismatch')
    require(info['MinimumOSVersion'] == '15.0', 'Deployment mismatch')
    require(info.get('CFBundleShortVersionString') == metadata['Version'],
            f'{directory}: bundle release version must match the package version')
    require(info.get('CFBundleVersion') == engine_version,
            f'{directory}/Resources/Info.plist: CFBundleVersion is '
            f'{info.get("CFBundleVersion")!r}; expected "{engine_version}" for {metadata["Version"]}. '
            'All app and provider bundle versions must match.')
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
for old in ('Sources', 'Preferences', 'NetShield.plist', 'NetShield2.plist', 'projectstructure.md'):
    require(not (ROOT / old).exists(), f'Obsolete v1 input remains: {old}')

if args.stage:
    app = args.stage / 'var/jb/Applications/NetShield2.app'
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
    allowed = {'var/jb/Applications/NetShield2.app', 'DEBIAN'}
    for file in args.stage.rglob('*'):
        if file.is_file():
            relative = file.relative_to(args.stage).as_posix()
            require(any(relative.startswith(prefix + '/') for prefix in allowed), f'Unexpected package file: {relative}')
    print('Validated rootless app, embedded providers, arm64 binaries and package scope')
else:
    print('Validated v2 metadata, source paths, entitlements, scripts and v1 cleanup')

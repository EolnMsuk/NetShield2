"""Compile/link iOS sources with portable Zig/Clang; does not run iOS binaries.

Use an extracted iOS SDK with its library aliases intact. On Windows, SDK file
symlinks may be materialized as copies of their archive targets. Output binaries
are validation artifacts, not signed/entitled installation packages.
"""
import argparse
import json
import pathlib
import struct
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--zig', required=True, type=pathlib.Path)
parser.add_argument('--sdk', required=True, type=pathlib.Path)
parser.add_argument('--output', required=True, type=pathlib.Path)
args = parser.parse_args()
zig, sdk, output = args.zig.resolve(), args.sdk.resolve(), args.output.resolve()
if not zig.is_file() or not (sdk / 'usr/lib/libobjc.tbd').is_file():
    raise SystemExit('Need a Zig executable and an iOS SDK with library aliases restored.')
output.mkdir(parents=True, exist_ok=True)

common = ['Shared/NSPolicy.m', 'Shared/NSStore.m']
targets = [
    ('NetShield', ['App/main.m'] + common,
     ['UIKit', 'Foundation', 'NetworkExtension', 'UserNotifications'], False),
    ('NetShieldData', ['FilterData/FilterDataProvider.m'] + common,
     ['Foundation', 'NetworkExtension'], True),
    ('NetShieldControl', ['FilterControl/FilterControlProvider.m', 'Shared/NSPermissionQueue.m'] + common,
     ['Foundation', 'NetworkExtension', 'UserNotifications'], True),
]
sources = sorted({source for _, files, _, _ in targets for source in files})
sources += ['Tests/policy_test.m', 'Tests/permission_test.m', 'Tests/response_test.m']
base = [str(zig), 'cc', '-target', 'aarch64-ios.16.0', '-isysroot', str(sdk)]
compile_flags = ['-fobjc-arc', '-fobjc-runtime=ios-16.0', '-fblocks',
                 '-iframework', str(sdk / 'System/Library/Frameworks'),
                 '-isystem', str(sdk / 'usr/include'),
                 '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter']
results = []

def run(label, command):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    diagnostics = result.stdout + result.stderr
    results.append(dict(check=label, command=command, exit=result.returncode, diagnostics=diagnostics))
    print(('PASS ' if result.returncode == 0 else 'FAIL ') + label, flush=True)
    if diagnostics:
        print(diagnostics, flush=True)
    return result.returncode == 0

def object_file(source):
    return output / (source.replace('/', '_') + '.o')

def check_macho(path, expected_type):
    magic, cpu, _, kind = struct.unpack_from('<IIII', path.read_bytes())
    if (magic, cpu, kind) != (0xfeedfacf, 0x100000c, expected_type):
        raise SystemExit(f'Unexpected Mach-O architecture/type: {path}')

for source in sources:
    extension = ['-fapplication-extension'] if source.startswith(('Shared/', 'FilterData/', 'FilterControl/')) else []
    if run('compile ' + source, base + compile_flags + extension + ['-c', source, '-o', str(object_file(source))]):
        check_macho(object_file(source), 1)

if all(result['exit'] == 0 for result in results):
    for name, files, frameworks, extension in targets:
        command = base + ['-F', str(sdk / 'System/Library/Frameworks'),
                          '-L', str(sdk / 'usr/lib'), '-lobjc', '-lc']
        command += [str(object_file(source)) for source in files]
        for framework in frameworks:
            command += ['-framework', framework]
        if extension:
            command += ['-fapplication-extension', '-Wl,-e,_NSExtensionMain']
        if run('link ' + name, command + ['-o', str(output / name)]):
            check_macho(output / name, 2)

(output / 'validation.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
if any(result['exit'] for result in results):
    raise SystemExit(1)
print('9 source compiles and 3 links passed. Tests were compiled, not executed. Use Theos for deployment.')

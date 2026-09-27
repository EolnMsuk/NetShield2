"""Exercise the stage validator with temporary fixtures; no simulated firewall claims."""
import pathlib
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='netshield-validation-') as temporary:
    stage = pathlib.Path(temporary)
    app = stage / 'var/jb/Applications/NetShield2.app'
    for directory, binary in [('App', 'NetShield2'), ('FilterData', 'NetShield2Data'), ('FilterControl', 'NetShield2Control')]:
        bundle = app if directory == 'App' else app / f'PlugIns/{binary}.appex'
        bundle.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / directory / 'Resources/Info.plist', bundle / 'Info.plist')
        (bundle / binary).write_bytes(struct.pack('<III', 0xfeedfacf, 0x100000c, 0))
    def validate(success):
        result = subprocess.run([sys.executable, str(root / 'scripts/validate.py'), '--stage', str(stage)], capture_output=True, text=True)
        if (result.returncode == 0) != success:
            raise AssertionError(result.stdout + result.stderr)
    validate(True)
    provider = app / 'PlugIns/NetShield2Data.appex/NetShield2Data'
    data = provider.read_bytes()
    provider.unlink()
    validate(False)
    provider.write_bytes(b'not a binary')
    validate(False)
    provider.write_bytes(data)
    leak = stage / 'var/jb/Library/MobileSubstrate/DynamicLibraries/NetShield2.dylib'
    leak.parent.mkdir(parents=True)
    leak.write_bytes(b'old tweak')
    validate(False)
    leak.unlink()
    unexpected = stage / 'var/jb/old-file.txt'
    unexpected.write_text('old')
    validate(False)
    unexpected.unlink()
    info_path = app / 'PlugIns/NetShield2Data.appex/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['NSExtension']['NSExtensionPointIdentifier'] = 'wrong'
    info_path.write_bytes(plistlib.dumps(info))
    validate(False)
print('Passed 6 stage-validation fixture tests')

# Alpha 3 local compiler validation

Completed on 2026-09-27 using portable Zig 0.14.1 / Clang, targeting arm64 iOS 16.0 with the same iPhoneOS16.5 SDK used by GitHub CI. The Zig archive matched the checksum published in Zig's download index; the SDK matched the checksum pinned in the workflow.

Results:

- All eight production and test Objective-C translation units compiled into arm64 Mach-O objects with ARC, blocks, `-Wall -Wextra -Werror` and only the existing unused-parameter suppression.
- Shared code and both providers compiled with `-fapplication-extension` restrictions.
- NetShield, NetShieldData and NetShieldControl linked against their required iOS frameworks. Provider executables linked with the `_NSExtensionMain` entry point.
- Source/package metadata checks and all six packaging fixture tests passed.
- No source corrections were required by these compiler/linker checks.

Reproduce with:

```text
python scripts/cross_compile.py --zig PATH_TO_ZIG --sdk PATH_TO_iPhoneOS16.5.sdk --output TEMP_OUTPUT_DIRECTORY
```

The command records exact commands and diagnostics in `validation.json` in the output directory. Windows extraction must preserve SDK file aliases, either as symlinks or copies of their archive targets. This affects the temporary SDK, not project source.

These checks do not execute the policy or permission-queue tests, sign entitlement-bearing binaries, build a Theos deb, or exercise the device. GitHub's macOS workflow runs the Foundation tests and builds/verifies the package. Alpha 2 activation and basic blocking were confirmed by the owner; alpha 3 notification delivery, user decisions and flow timing still require iOS execution.

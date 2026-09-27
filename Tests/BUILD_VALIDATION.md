# Alpha 5 local compiler validation

Completed on 2026-09-27 using portable Zig 0.14.1 / Clang, targeting arm64 iOS 16.0 with the same iPhoneOS16.5 SDK used by GitHub CI. The Zig archive matched the checksum published in Zig's download index; the SDK matched the checksum pinned in the workflow.

Results:

- All nine production and test Objective-C translation units compiled into arm64 Mach-O objects with ARC, blocks, `-Wall -Wextra -Werror` and only the existing unused-parameter suppression.
- Shared code and both providers compiled with `-fapplication-extension` restrictions.
- NetShield, NetShieldData and NetShieldControl linked against their required iOS frameworks. Provider executables linked with the `_NSExtensionMain` entry point.
- Source/package metadata checks and all six packaging fixture tests passed.
- Notification-response validation tests compile and are added to macOS CI (11 checks for decisions, stale/stopped providers, mismatched identities/tokens and duplicate actions).

Reproduce with:

```text
python scripts/cross_compile.py --zig PATH_TO_ZIG --sdk PATH_TO_iPhoneOS16.5.sdk --output TEMP_OUTPUT_DIRECTORY
```

The command records exact commands and diagnostics in `validation.json` in the output directory. Windows extraction must preserve SDK file aliases, either as symlinks or copies of their archive targets. This affects the temporary SDK, not project source.

These checks do not execute the policy or permission-queue tests, sign entitlement-bearing binaries, build a Theos deb, or exercise the device. GitHub's macOS workflow runs the Foundation tests and builds/verifies the package. Activation, basic blocking and alpha 3 in-app decisions were confirmed by the owner. Alpha 5 notification delivery and background decisions still require iOS execution.

Alpha 5 adds system-app notification metadata (required by the validator) and a configuration-removal-first reset. These paths compile/link but their iOS registration and provider-stop behavior cannot be executed by the Windows compiler.

Alpha 6 (2026-09-27): all nine source compiles and three links pass; metadata and six package fixtures pass. Foundation tests are compiled locally, executed only in macOS CI. App and provider notification diagnostics have not been executed on-device. No successful delivery claim is made.

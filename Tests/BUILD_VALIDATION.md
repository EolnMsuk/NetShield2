# Release build validation

The local Windows validation uses Zig 0.14.1 / Clang, targeting arm64 iOS 16.0 with the pinned iPhoneOS16.5 SDK. It compiles all nine production/test translation units with ARC, blocks and warnings treated as errors, then links NetShield and both providers. Shared/provider sources compile under app-extension restrictions.

Run `python scripts/validate.py` and `python Tests/validation_test.py` for metadata/package fixtures. Use `scripts/cross_compile.py --zig PATH --sdk PATH --output TEMP_DIRECTORY` for compile/link validation.

GitHub macOS CI executes the Foundation policy, permission-queue and response tests; packages with Theos; checks rootless staging and signed entitlements. Local cross-compilation does not execute Foundation tests, sign a deb, or exercise iOS UI. The final release UI and package icon still require the device checklist.

The backend preserves exact OS app identities, a bounded permission queue, 30-second timeout, atomic policy writes and background notification response validation. Saved rules and app-group identity remain compatible with pre-release builds. The working deployment entitlements are deliberately retained.

# NetShield 2

OS-level network access control for rootless iOS 16, with a Home Screen app, a Network Extension data provider and a separate control provider. Current build: **2.0.0~alpha4**.

The owner has confirmed that alpha 2 builds, installs, enables both providers, reports OS flows, and blocks the traffic they tried when the default rule is Block on **iOS 16.1.1 / Dopamine 3.0.10**. Comprehensive protocol coverage and reliable attribution of every system flow have not been established. The owner also confirms alpha 3 in-app prompts work. Alpha 4 fixes notification action handling and setup, and adds settings diagnostics, a delivery test and retries. Its background delivery still needs device validation.

## Use

See [the complete installation and feature test guide](Tests/USER_GUIDE.md), including notification Settings, the five-second delivery test, and the report-back checklist. No respring or userspace reboot is required for this app/provider-only package.

1. Install the alpha 4 deb and open **NetShield**.
2. Tap **Start permission prompts**, then allow notifications when iOS asks. This selects Ask for apps without a rule, retains existing app decisions, and starts or restarts the filter through NetworkExtension. Restarting briefly disables filtering.
3. Open another app and make a new network request. Use **Allow app** or **Block app** in the notification, or open NetShield's **Permission requests** section. Decisions are saved for future incoming and outgoing flows from that exact OS identity.
4. If a connection has timed out before you answer, save the rule and retry the app's request. Change saved rules under **Apps and OS identities**.

There is no need to enter an app identifier manually for observed requests. NetShield uses the exact identity iOS supplies, including any signing prefix.

**Start permission prompts preserves existing explicit rules.** To make a previously decided app ask again, select its identity and choose `use-default`. Reset rules clears all decisions, restores Ask, and allows unattributed traffic. Upgrades otherwise retain existing policy, including the unattributed-flow setting.

## Permission behavior

- With default **Ask**, new attributed flows without an explicit app rule return `needRulesVerdict`. The control provider retains their completion handlers while the user decides.
- The pending queue has a 30-second monotonic deadline, checked once a second. Unanswered flows are denied. An app can time out sooner. A late Allow saves a rule for a retry; it cannot resurrect a closed connection.
- Multiple attempts from one identity share one prompt. An expired unresolved request remains in the inbox, and retries are immediately denied until a rule is saved. This prevents repeated notification floods from an app retrying.
- Limits are 64 unresolved identities, 16 held flows per identity and 256 held flows in total. Overflow is denied. Stopping the control provider resolves outstanding callbacks as denied.
- Local notifications offer **Allow app** and **Block app** actions. Long-press the banner to show actions. Actions save the decision in the background and require unlocking; tapping the body opens NetShield. The shared response handler validates the token, identity, current heartbeat and absence of an existing decision before saving a rule. Stale notifications cannot change policy.
- The app also presents requests while it is open. If notification permission is denied, notifications are suppressed by Focus, or iOS rejects scheduling from the control extension, the inbox remains available and the deadline still denies unanswered flows. Scheduling errors appear in Status. **Background notification delivery from this provider is not yet device-verified.**
- Allow/Block saves an app-wide rule, rather than asking repeatedly for every packet. Unattributed flows cannot be reliably presented as a named app and therefore use their separate Allow/Block setting.

## Status and monitoring

**Filtering active** means the saved filter is enabled, a control heartbeat is less than eight seconds old, and OS activity was recorded within 30 seconds. When idle, the display says **Filter enabled: no recent traffic**. A missing heartbeat is shown explicitly. These signals do not certify coverage of every network path.

The monitor retains the latest 300 events per provider session. OS flow-close reports supply byte counts; permission decisions are recorded separately. Payloads, URLs and destinations are not persisted. The data provider only reads shared policy and returns verdicts. It does not send notifications or export flow data through custom IPC.

Rules are applied at **new-flow admission**. Existing allowed connections retain their verdict until closed; iOS does not expose the macOS flow-update API. Initially inbound/outbound refers to the direction in which the connection starts, not the direction of reply packets. No protection is promised for raw IP/ICMP, kernel or OS-exempt paths, before provider startup, or while the jailbreak/filter is unavailable.

## Build

Upload this source tree at the root of the GitHub repository, including **all three Resources/Info.plist files**. Run **Actions > Build NetShield 2 experimental** on the new commit. The workflow installs pinned Theos and SDK versions, checks metadata, runs policy and permission-queue tests, builds the app/providers, verifies staged binaries and signed entitlements, and uploads:

`NetShield-2-experimental-iOS16-rootless`

containing `com.eolnmsuk.netshield_2.0.0~alpha4_iphoneos-arm64.deb`.

A Mac with Theos and the 16.5 SDK can run `make package FINALPACKAGE=1`. Apps/extensions are arm64 and also run on arm64e devices. No socket-hook or SpringBoard injection library is built.

Local validation now uses portable Zig/Clang with the pinned iOS SDK. All nine production/test source files compile with warnings treated as errors, and the app plus both providers link successfully as arm64 iOS executables. See [the compiler validation record](Tests/BUILD_VALIDATION.md). The local cross-compiler does not execute iOS binaries or Foundation tests; GitHub runs the tests and builds the signed Theos package. Runtime notification delivery, flow waiting behavior and OS bypasses still require device validation.

## Deployment and removal

Alpha 1's NEFilterErrorDomain 5 activation failure was followed by the owner's successful alpha 2 activation report. The app retains `get-task-allow`, Apple's development-only configuration exception. It makes the app debuggable and is not a production deployment entitlement. Normal iOS distribution of system-wide content filters has supervision/child-authorization restrictions. This is an experimental jailbreak deployment, with evidence limited to the reported device.

Use **Remove filter configuration** before uninstalling. The package removal script unregisters the app, but does not independently remove or verify OS filter preferences. If removed prematurely, reinstall the same app to remove its configuration. Upgrades from v1 still require unloading its old injected dylibs; v2 uses separate OS-hosted providers.

## Source and tests

| Path | Purpose |
| --- | --- |
| App | Dashboard, configuration, foreground prompts and notification decisions |
| FilterData | OS new-flow decisions and requests for permission |
| FilterControl | Bounded permission waits, OS reports and local notifications |
| Shared | Policy validation, permission queue, app-group storage and notification actions |
| Tests | Policy/queue unit tests, package fixtures and device coverage record |
| scripts | Metadata, package and signed-entitlement validation |
| layout/DEBIAN | Rootless registration and removal scripts |

Local checks: `python scripts/validate.py` and `python Tests/validation_test.py`. CI additionally runs `Tests/policy_test.m`, `Tests/permission_test.m` and `Tests/response_test.m`. Queue tests cover coalescing, per-direction decisions, exactly-once completion, timeout, late consent, invalid policy, queue limits and shutdown cancellation.

## References

- [Apple: filter manager and development exception](https://developer.apple.com/documentation/networkextension/nefiltermanager)
- [Apple: control-provider new-flow decisions](https://developer.apple.com/documentation/networkextension/nefiltercontrolprovider/handlenewflow(_:completionhandler:))
- [Apple: provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
- [Theos: rootless packaging](https://theos.dev/docs/rootless)

MIT License. Copyright 2026 EolnMsuk.

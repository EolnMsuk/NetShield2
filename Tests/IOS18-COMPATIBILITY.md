# iOS 17/18 content-filter investigation

Investigated 2026-10-01 for iOS 18.2 / Relaxin 0.5.4 / iphoneos-arm64e.

## Findings and confidence

The symptoms point to provider activation or startup failure, before normal
permission handling. They do not identify a particular Apple error code: the
Settings label "Invalid" is not a captured NEFilterManagerError value.

The app successfully saving a configuration does not prove that either embedded
extension launched. The data provider must read policy.plist before completing
startup. The control provider must acquire provider.lock, read policy.plist and
publish monitor.plist. Failure at any of these stages prevents a healthy startup.
Requests needing a decision cannot receive the normal permission notification
until the control provider is working.

**Confirmed recovery defect:** NSFilterRestart previously left a newly enabled
configuration enabled when the control provider failed its 15-second startup
check. Exhausted rollback could leave an enabled, unhealthy configuration too.
This can prolong traffic disruption while iOS attempts to start the providers.
The update persists OFF and reloads preferences to verify OFF after these failures.
If cleanup fails, it explicitly directs the tester to disable the Content Filter
in Settings. Rules are retained. A healthy previous configuration can still be
restored. Automatic disable means NetShield2 is no longer protecting traffic;
the app reports that explicitly.

**Candidate startup cause, not proven on the reporter's phone:** RootHide's
documented jailbreak executable entitlements are absent from the providers, and
only platform-application is present in the app. This was verified in both the
source plists and the signed executables inside the supplied 2.2.6 debs. A deb's
iphoneos-arm64e package label selects the RootHide deployment; it does not grant
the embedded extensions the app's entitlements. All three executables are signed
separately.

No device console or crash report was provided. Registration, signing/trust,
sandbox/container access, or another filter can produce similar symptoms. Do not
describe the entitlement hypothesis as a confirmed iOS 18 regression or this
build as a verified iOS 18 startup fix.

## Relevant platform differences

| Area | iOS 16 / Dopamine RootHide | iOS 17/18 / Relaxin RootHide |
| --- | --- | --- |
| NetworkExtension | Data/control app extensions and content-filter-provider entitlement | Same provider model; no evidence that iOS 18 requires a different extension point or a replacement filtering API |
| Jailbreak deployment | RootHide relocation, signing and sandbox behavior | Same RootHide architecture, with version-specific launch/trust/RunningBoard integration; iOS 16 success does not establish iOS 18 compatibility |
| Devices | Depends on Dopamine release and device | Official current Relaxin site lists iOS 18 support for A12/A13; the archived August source snapshot only describes 16.5.1-17.3.1 |
| Security architecture | Device/version dependent | SPTM is not a universal explanation for an iOS 18 report; do not assume the reporter has an A15+ device |
| Filter health | This app's monitor measures the control provider | Same limitation: a fresh control heartbeat alone does not establish successful data-provider startup or traffic coverage |

The iOS 16.5 SDK is not itself evidence of a runtime incompatibility. The used
content-filter APIs predate iOS 17. In that SDK, explicit data-provider bundle
selection and applySettings are macOS-only APIs; do not add them unguarded as
an alleged iOS 18 fix. The existing extension point IDs match Apple's model.

## RootHide-only entitlement experiment (applied with user approval)

The exact entitlement additions are the following booleans,
all true, in separate RootHide-only signing plists for NetShield2,
NetShield2Data and NetShield2Control:

```xml
<key>platform-application</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.private.security.storage.AppBundles</key><true/>
<key>com.apple.private.security.storage.AppDataContainers</key><true/>
```

Each component keeps its current application identifier, application group and
content-filter-provider entitlement, with get-task-allow retained in the app.
The Makefiles select these files only with THEOS_PACKAGE_SCHEME=roothide. Source
validation checks the exact merged entitlement set, and CI verifies each signed
executable. Rootless retains its current entitlements.

These are RootHide's published general executable requirements, not an
Apple-documented fix for NEFilterDataProvider. They broaden platform and storage
access and request exemption from the normal sandbox, including for the component
that sees network content. We cannot assume the data provider's isolation remains
equivalent with them. This experiment was applied after explicit user approval.
Rootless builds retain their original entitlements. CI checks all three signed
executables against the selected scheme, and source validation permits exactly
these four additions to each component's existing entitlement set.

## Tester procedure

1. Disable Firewall and, if necessary, remove the old Content Filter in Settings
   before installing the new build. Keep saved rules; a full reset is unnecessary.
2. Install the 2.2.7 (engine 20026) iphoneos-arm64e artifact from the roothide Actions job. Open
   NetShield2. Record its version/build, the device model, iOS build and Relaxin
   version. Confirm the jailbreak is active and NetShield2 is not excluded by Umbra.
3. Start a device console capture before enabling Firewall. On a Mac use Console
   with the connected iPhone selected; include info/default and error messages.
   Search for subsystem com.eolnmsuk.netshield / category ProviderLifecycle.
   Also capture neagent, nesessionmanager, nehelper, runningboardd, lsd and sandbox
   errors involving the app or either extension. Collect relevant .ips crash
   reports if an extension terminates. Omit unrelated private traffic logs.
4. Enable Firewall and allow the system content-filter prompt. Keep NetShield2
   foregrounded until activation or recovery completes. The 15-second wait is
   app-scheduled and can pause while the app is suspended; it is not an independent
   system watchdog. An initially enabled filter can take another startup interval
   if the app tries to restore its previous configuration.
5. A successful result needs both providers' ready messages for the current
   activation, Settings showing Running, and successful real connection tests.
   Test an app without a saved rule: ask, allow, retry, then block and retry.
   Check both Wi-Fi and cellular and repeat after a userspace reboot/re-jailbreak.
   Also regress iOS 16 Dopamine RootHide and the rootless build.
6. If startup fails, expect an error and Firewall OFF after recovery. Verify that
   networking recovers. If the error says automatic disable failed, disable/remove
   the filter in Settings. Do not interpret OFF as firewall protection.

## Reading the new lifecycle logs

| Last observed stage | Next investigation |
| --- | --- |
| No initialized message for one/both providers | Check PlugInKit/LaunchServices registration, launch denial, trust/signature, dyld and crash reports; absence of a log alone is not proof the process never ran |
| initialized but no starting | NetworkExtension host/session handshake, framework or process failure |
| data policy-read-failed | Data-provider app-group visibility, read permission, missing/corrupt policy |
| control provider-lock-failed | Shared container access, lock-file permissions, or a previous provider still alive |
| control policy-read-failed | Control-provider policy access or validation |
| control monitor-write-failed | Control-provider shared-container write/atomic-rename permissions |
| Both ready, Settings still not Running | Framework/session failure after callbacks; inspect system logs and check for a second filter |
| Both ready, no prompts | Check new flows, default rule, existing rules, notifications, and control-provider flow handling |

Logs contain lifecycle stage, component, engine, activation UUID, OS version and
NSError domain/code/description, not flow payloads or destination records. The
data provider does not write shared heartbeat files. App health checks also
require the monitor's activation UUID to match the current configuration, avoiding
a stale previous provider being displayed as healthy.

## Primary references

- [Apple: NEFilterProvider](https://developer.apple.com/documentation/networkextension/nefilterprovider): separate data/control roles and data-provider sandbox restrictions.
- [Apple: startFilter](https://developer.apple.com/documentation/networkextension/nefilterprovider/startfilter(completionhandler:)): completion reports startup success/failure.
- [Apple: Network Extension deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment): stock-device restrictions; these must not be confused with jailbreak deployment or a saved configuration's runtime health.
- [Apple DTS: development signing affordance](https://developer.apple.com/forums/thread/827318): get-task-allow concerns permission to save a filter configuration, not proof of extension startup.
- [RootHide developer documentation](https://github.com/roothide/Developer): package scheme, relocated paths and executable entitlements.
- [RootHide entitlement requirements](https://github.com/roothide/Developer/blob/main/entitlements.md): the proposed four boolean entitlements.
- [Dopamine RootHide](https://github.com/roothide/Dopamine2-roothide): iOS 15/16 lineage.
- [Official Relaxin site](https://relaxin.owngoal.dev/): current device support and release notes. Its October 1 site bundle lists 0.5.4 and the 0.5.1 expansion to A12/A13 on 17.4-18.7.1.
- [Relaxin archived source](https://github.com/owngoal-dev/Relaxin): August 19 snapshot, explicitly not updated to reflect all later releases; not proof of 0.5.4 implementation details.

## Validation scope

Local checks passed: release metadata, Objective-C formatting, syntax for all 19
Objective-C translation units using the existing iOS 16.5 SDK/libclang toolchain,
and six entitlement-profile checks plus twelve negative checks (wrong scheme or
an unexpected entitlement). These signing-check fixtures validate the checker;
only CI's ldid extraction verifies the newly linked executables' signatures.

The regression suite now covers 16 restart/recovery scenarios and stale/malformed
heartbeat cases. Native Foundation regression execution, POSIX uninstall-script
tests and Theos linking/packaging could not run on this Windows host and remain
in the macOS GitHub Actions jobs. Device launch, sandbox behavior and real
filtering require the tester's phone; no local source check establishes those
outcomes.

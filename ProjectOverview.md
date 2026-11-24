# NetShield2

## Overview

NetShield2 is a firewall, network monitor, and content filter for jailbroken iOS 15–18 devices using rootless, RootHide, or rootful packages.

## GitHub build and release

| Variant | `THEOS_PACKAGE_SCHEME` | Debian architecture | App path inside the extracted package |
| --- | --- | --- | --- |
| rootless | `rootless` | `iphoneos-arm64` | `var/jb/Applications/NetShield2.app` |
| RootHide | `roothide` | `iphoneos-arm64e` | `Applications/NetShield2.app` |
| rootful | empty string | `iphoneos-arm` | `Applications/NetShield2.app` |

## Project file map

```text
NetShield2/
+-- .clang-format                      # Sets the Objective-C formatting rules used by CI.
+-- .github/
|   +-- workflows/
|       +-- build.yml                  # Checks and packages all three variants. Main-branch pushes prepare a verified draft release.
+-- App/
|   +-- Entitlements.plist             # Declares the app's signing entitlements.
|   +-- Makefile                       # Defines the app target, sources, frameworks, and signing options. Sets the raw NS_JAILBREAK_TYPE from the Theos scheme.
|   +-- NSAppDelegate.h                # Declares the app lifecycle and notification delegate.
|   +-- NSAppDelegate.m                # Registers/resumes configuration execution, launches the dashboard, and handles notification responses.
|   +-- NSAppStorage.h                 # Declares the serial storage queue and UIKit configuration execution registration/resumption.
|   +-- NSAppStorage.m                 # Creates the storage queue and supplies bounded UIKit background execution for configuration work.
|   +-- NSConfigurationCoordinator.h   # Declares configuration transactions, save receipts, recovery states, and bounded local mutation access.
|   +-- NSConfigurationCoordinator.m   # Serializes preference operations with save receipts, durable reservations/pending records, recovery, and local execution budgets.
|   +-- NSDashboard+Configuration.m    # Manages filter configuration, upgrades, and fallback verification. Restores expanded sections on reset and uses the raw package identifier in diagnostics.
|   +-- NSDashboard+Internal.h         # Declares dashboard section and row enums, controller state, and shared category methods.
|   +-- NSDashboard+Notifications.m    # Authorizes notifications and presents, defers, and answers permission requests.
|   +-- NSDashboard+Table.m            # Renders sections and rows, dispatches taps including Support actions, and manages scrolling, activity search, and section collapse. Maps package identifiers to display names in the Support version label.
|   +-- NSDashboard+Updates.m          # Schedules update checks and presents update options and release results.
|   +-- NSDashboard.h                  # Declares the main dashboard controller.
|   +-- NSDashboard.m                  # Manages the dashboard lifecycle, storage snapshots, rule editing, and transfers. Opens Support links and presents donation prompts.
|   +-- NSFilterBootPolicy.h           # Declares boot fallback checks and migration helpers.
|   +-- NSFilterBootPolicy.m           # Applies and verifies the stock-boot fallback setting.
|   +-- NSFilterRemoval.h              # Declares verified filter removal and shared-state cleanup.
|   +-- NSFilterRemoval.m              # Verifies preference removal before retrying shared-state cleanup.
|   +-- NSFilterRestart.h              # Defines the filter restart interface and result states.
|   +-- NSFilterRestart.m              # Stages, verifies, and rolls back filter restarts as needed.
|   +-- NSGlobalRuleEditor.h           # Declares the global rule editor and its save callback.
|   +-- NSGlobalRuleEditor.m           # Edits global rule conditions and actions with manual app identity entry and the app picker.
|   +-- NSReleaseFetch.h               # Declares the bounded release fetcher and response buffer.
|   +-- NSReleaseFetch.m               # Streams GitHub release data with size and redirect checks.
|   +-- NSRespring.h                   # Declares the respring launcher and its test hook.
|   +-- NSRespring.m                   # Uses the raw package identifier to choose sbreload paths, launches the executable, and reaps the child process.
|   +-- NSRuleActionController.h       # Declares the reusable rule and connection action controller.
|   +-- NSRuleActionController.m       # Displays rule actions, selections, and connection details and handles copying displayed values.
|   +-- NSRuleAppearance.h             # Provides adaptive action colors for rule rows, activity rows, and action pickers.
|   +-- NSSectionTypography.h          # Supplies shared text styles for table section headers.
|   +-- Resources/
|   |   +-- GitHubLogo.png             # Provides the dashboard's GitHub Link icon.
|   |   +-- Icon.png                   # Provides the app icon and package icon asset.
|   |   +-- Info.plist                 # Provides the app bundle metadata template.
|   |   +-- Reddit@2x.png              # 2x artwork for Reddit Link (58 x 58 pixels).
|   |   +-- Reddit@3x.png              # 3x artwork for Reddit Link (87 x 87 pixels).
|   |   +-- banner.png                 # Provides the banner used by the Sileo depiction.
|   +-- main.m                         # Starts the app or runs the package uninstall helper.
+-- FilterControl/
|   +-- Entitlements.plist             # Declares the control extension's signing entitlements.
|   +-- FilterControlProvider.m        # Coordinates flow decisions, permission requests, and DNS updates. Publishes activity and health through monitor snapshots.
|   +-- Makefile                       # Defines the control extension target and signing options.
|   +-- NSDomainResolver.h             # Declares the DNS resolver and injectable lookup interfaces.
|   +-- NSDomainResolver.m             # Schedules DNS lookups and handles retries and cancellation.
|   +-- NSPermissionNotifications.h    # Declares monitor snapshot publication and permission notification delivery interfaces.
|   +-- NSPermissionNotifications.m    # Publishes monitor snapshots and uses current request-level policy checks to send, retry, and withdraw permission notifications.
|   +-- NSProviderWorkQueue.h          # Declares the bounded serial work queue and reply admission gate for the provider.
|   +-- NSProviderWorkQueue.m          # Bounds queued work and outstanding replies, and delivers each reply completion at most once.
|   +-- Resources/
|       +-- Info.plist                 # Registers the Network Extension control provider.
+-- FilterData/
|   +-- Entitlements.plist             # Declares the data extension's signing entitlements.
|   +-- FilterDataProvider.m           # Evaluates new and deferred flows using shared policy and invalidates the policy cache when rules change.
|   +-- Makefile                       # Defines the data extension target and signing options.
|   +-- Resources/
|       +-- Info.plist                 # Registers the Network Extension data provider.
+-- Makefile                           # Builds all three targets and runs the Debian packaging hooks.
+-- Shared/
|   +-- NSActivity.h                   # Groups activity and shares connection-sheet, search, and clipboard details.
|   +-- NSAppPreferences.h             # Defines validated section preferences with expanded defaults, update-check preferences, and whole-domain app reset helpers.
|   +-- NSBootSession.h                # Looks up the current system boot identity when available.
|   +-- NSBoundedFile.h                # Declares pinned app-group directories, checked descriptors, and bounded file reads/writes/removal.
|   +-- NSBoundedFile.m                # Validates paths/descriptors and performs bounded I/O, atomic writes, and safe removal.
|   +-- NSConstants.h                  # Defines the filter engine version used as the bundle build number, shared data schema versions, limits, and filenames.
|   +-- NSDNSCache.h                   # Checks DNS answer expiry and merges results into policy.
|   +-- NSDestination.h                # Validates destinations and formats hosts before direction/protocol in connection details.
|   +-- NSExport.h                     # Declares rule import parsing, immutable import results, and rules and activity export APIs.
|   +-- NSExport.m                     # Parses rule imports with 3.0.0 classifier compatibility and rejection counts. Serializes rules and activity and manages bounded export staging.
|   +-- NSFlowDestination.h            # Extracts hosts, ports, and protocol from iOS filter flows.
|   +-- NSGlobalRule.h                 # Declares global-condition parsing, canonical keys, overlap validation, and matching.
|   +-- NSGlobalRule.m                 # Parses CIDRs and port ranges, compiles conditions, rejects overlaps, and matches raw identities and endpoints.
|   +-- NSIdentityDisplay.h            # Formats shortened app labels and full process names from raw identities.
|   +-- NSMonitorSchema.h              # Declares validation for shared monitor snapshots.
|   +-- NSMonitorSchema.m              # Validates monitor fields, activity records, and request entries.
|   +-- NSNotificationPolicy.h         # Determines when to withdraw stale permission notifications.
|   +-- NSNotifications.h              # Registers/validates direction-aware permission actions and withdraws banners for automatic system and third-party actions.
|   +-- NSPermissionQueue.h            # Declares the queue for flows waiting on user decisions.
|   +-- NSPermissionQueue.m            # Settles held flows with shared evaluation of captured directions/peers and handles timeouts.
|   +-- NSPermissionRequest.h          # Defines canonical request fingerprints, scope, and presentation checks.
|   +-- NSPolicy.h                     # Defines raw system classification, the telemetry list interface and shared verdict APIs.
|   +-- NSPolicy.m                     # Defines the 20 telemetry identities, validates system and third-party traffic settings and evaluates precedence for all callers.
|   +-- NSPolicyCache.h                # Declares policy caching and invalidation.
|   +-- NSPolicyCache.m                # Tracks policy file identity and caches validated snapshots.
|   +-- NSPolicyReader.h               # Declares the shared policy reader and app-group path helpers.
|   +-- NSPolicyReader.m               # Locates the app-group container and reads policy through its cache.
|   +-- NSProviderHealth.h             # Checks whether a control provider heartbeat is current.
|   +-- NSReleaseVersion.h             # Validates release versions and compares their numeric parts.
|   +-- NSRuleChoices.h                # Defines rule choices and directional selection behavior.
|   +-- NSStore.h                      # Declares shared policy, monitoring, and cleanup operations.
|   +-- NSStore.m                      # Manages shared policy, monitor and request storage, and shared-state cleanup. Applies rule imports atomically and validates presented permission requests before applying responses.
|   +-- NSConfigurationRecord.h        # Declares configuration record admission, revocable access tokens, and local execution budget hooks.
|   +-- NSConfigurationRecord.m        # Validates durable records/reservations and queued access, enforcing execution budgets around short physical locks.
|   +-- NSStoreLock.h                  # Declares the shared filesystem lock.
|   +-- NSStoreLock.m                  # Acquires and releases locks across the app and providers.
|   +-- NSValidation.h                 # Validates stored strings, Boolean values, and unsigned integers.
+-- Tests/
|   +-- BootPolicyTests.m              # Tests boot fallback, verified restarts/removal, authorization, migration, and external ownership/recovery.
|   +-- ConfigurationTests.m           # Tests save receipts/timeouts, durable recovery/reservations, and local execution budgets.
|   +-- HardeningTests.m               # Tests decision parity, bounded storage/queues/release bodies, DNS lifetimes, and activity generations/counters.
|   +-- RecoveryTests.m                # Tests destination safety, DNS recovery, notification retries/orphans, directional rule storage, and activity/rule clearing.
|   +-- RegressionTests.m              # Tests rules, storage, transfers, permission and notification handling, saved filter settings, and app preference defaults, persistence, and reset.
|   +-- RespringTests.m                # Tests respring launch and fallback with a mock launcher.
|   +-- RuleFixtures.h                 # Builds current-schema rule, DNS lifetime, and permission-request test fixtures.
+-- changelog.md                       # Records release history for the Sileo depiction and supplies the matching version entry for CI draft notes.
+-- control                            # Defines the Debian package ID, dependencies, and package version used as the bundle marketing version.
+-- depiction.json                     # Defines the Sileo header, Details, screenshots, and mirrored changelog. minVersion is the depiction schema version (0.4).
+-- layout/
|   +-- DEBIAN/
|       +-- postinst                   # Registers the app and defers respring until dpkg confirms the expected installed version.
|       +-- prerm                      # Runs the app's filter and shared-state cleanup helper before unregistering the app. Defers respring until package removal is verified.
+-- screenshots/                       # The Sileo depiction references 1SS.PNG through 9SS.PNG.
|   +-- 0SS.png                        # Additional screenshot.
|   +-- 1SS.PNG
|   +-- 2SS.PNG
|   +-- 3SS.PNG
|   +-- 4SS.PNG
|   +-- 5SS.PNG
|   +-- 6SS.PNG
|   +-- 7SS.PNG
|   +-- 8SS.PNG
|   +-- 9SS.PNG
|   +-- SS.PNG                         # Additional screenshot.
+-- scripts/
    +-- bundle_metadata.mk             # Runs sync_version.py to generate bundle Info.plist files before signing.
    +-- check_entitlements.py          # Compares signed entitlements against the source declarations.
    +-- check_format.py                # Checks Objective-C formatting with clang-format.
    +-- check_macho.py                 # Checks arm64 Mach-O metadata, the iOS deployment target, linked libraries, and embedded signing identifiers and hashes.
    +-- check_signing_identity.py      # Checks signing identifiers in packaged binaries using the Mach-O verifier.
    +-- prepare_draft.cjs              # Validates the three packages against their CI manifests, then stages and verifies the assets on a GitHub draft release.
    +-- prepare_package.py             # Substitutes the package version token and adjusts paths in the staged maintainer scripts for each variant.
    +-- release_manifest.py            # Records the final package hash, source and Theos revisions, pinned SDK hash, and build tool versions.
    +-- sync_version.py                # Sets CFBundleShortVersionString from control and CFBundleVersion from NSEngineVersion. Exports package metadata to CI.
    +-- test.py                        # Compiles and runs macOS regressions for shared code, filter configuration, and control-provider helpers with optional sanitizers, then runs isolated respring tests.
    +-- test_macho.py                  # Tests Mach-O validation with synthetic binaries and tampering.
    +-- test_packaging.py              # Tests bundle metadata generation, staged layouts, and maintainer scripts across the three variants.
    +-- test_prepare_draft.cjs         # Tests draft staging and retries with mocked GitHub calls.
    +-- test_respring.py               # Compiles and runs the native respring tests.
    +-- test_signing_identity.py       # Exercises the wrapper with synthetic signed binaries.
    +-- validate.py                    # Checks source inputs by default. With --stage, also validates a staged or extracted package tree.
```

## Supporting files and local tools

| File | Role |
| --- | --- |
| `README.md` | User guide and web depiction fallback. |
| `LICENSE` | MIT license. |
| `ProjectOverview.md` | Project file map, jailbreak package layouts, and supporting-file responsibilities. |
| `.theos-toolchain/` | Local iOS 16.5 SDK and archive, Clang resource headers, Python tools, and a syntax checker. |
| `scripts/check_objc.py` | Optional arm64 iOS 15 syntax check using the local SDK and libclang, with a package scheme selector. |
| `scripts/test_uninstall.py` | Exercises prerm cleanup and deferred respring with mock commands. test_packaging.py invokes it when POSIX sh is available. |

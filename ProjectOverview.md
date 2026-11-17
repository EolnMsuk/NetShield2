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
|       +-- build.yml                  # Checks/builds all three variants; main-branch pushes prepare verified draft releases.
+-- App/
|   +-- Entitlements.plist             # Declares the app's signing entitlements.
|   +-- Makefile                       # Defines the app target, sources, frameworks, and signing options.
|   +-- NSAppDelegate.h                # Declares the app lifecycle and notification delegate.
|   +-- NSAppDelegate.m                # Registers/resumes configuration execution, launches the dashboard, and handles notification responses.
|   +-- NSAppStorage.h                 # Declares the serial storage queue and UIKit configuration execution registration/resumption.
|   +-- NSAppStorage.m                 # Creates the storage queue and supplies bounded UIKit background execution for configuration work.
|   +-- NSConfigurationCoordinator.h   # Declares configuration transactions, save receipts, recovery states, and bounded local mutation access.
|   +-- NSConfigurationCoordinator.m   # Serializes preference operations with save receipts, durable reservations/pending records, recovery, and local execution budgets.
|   +-- NSDashboard+Configuration.m    # Manages filter configuration/upgrades and fallback verification; successful shared/app resets restore expanded sections.
|   +-- NSDashboard+Internal.h         # Shares dashboard rows/caches, collapse/search and gesture state, copy feedback, and the restoration helper used by launch/reset.
|   +-- NSDashboard+Notifications.m    # Manages notification authorization and permission requests passed to the shared custom-rule draft builder.
|   +-- NSDashboard+Table.m            # Maps section preference keys, restores/saves collapse choices, renders searchable/collapsible headers, and guards table/scroll refreshes and row press actions.
|   +-- NSDashboard+Updates.m          # Schedules update checks and displays available releases.
|   +-- NSDashboard.h                  # Declares the main dashboard controller.
|   +-- NSDashboard.m                  # Owns dashboard lifecycle, restores section choices at launch, snapshots storage, guards rule edits/transfers, and builds direction-specific custom-rule drafts.
|   +-- NSFilterBootPolicy.h           # Declares boot fallback checks and migration helpers.
|   +-- NSFilterBootPolicy.m           # Applies and verifies the stock-boot fallback setting.
|   +-- NSFilterRemoval.h              # Declares verified filter removal and shared-state cleanup.
|   +-- NSFilterRemoval.m              # Verifies preference removal before retrying shared-state cleanup.
|   +-- NSFilterRestart.h              # Defines the filter restart interface and result states.
|   +-- NSFilterRestart.m              # Stages, verifies, and rolls back filter restarts as needed.
|   +-- NSGlobalRuleEditor.h           # Declares the global rule editor and its save callback.
|   +-- NSGlobalRuleEditor.m           # Edits custom rules, prefixes only manual app identities, and maintains native App dropdown selections.
|   +-- NSReleaseFetch.h               # Declares the bounded release fetcher and response buffer.
|   +-- NSReleaseFetch.m               # Streams GitHub release data with size and redirect checks.
|   +-- NSRespring.h                   # Declares the respring launcher and its test hook.
|   +-- NSRespring.m                   # Starts the jailbreak respring tool and reaps its child process.
|   +-- NSRuleActionController.h       # Declares the reusable rule and connection action controller.
|   +-- NSRuleActionController.m       # Displays rule actions, selections, and connection details and handles copying displayed values.
|   +-- NSRuleAppearance.h             # Supplies shared colors and styles for rule actions.
|   +-- NSSectionTypography.h          # Supplies shared text styles for table section headers.
|   +-- Resources/
|   |   +-- GitHubLogo.png             # Provides the icon for the GitHub link.
|   |   +-- Icon.png                   # Provides the app icon and package icon asset.
|   |   +-- Info.plist                 # Provides the app bundle metadata template.
|   |   +-- banner.png                 # Provides the banner used by the Sileo depiction.
|   +-- main.m                         # Starts the app or runs the package uninstall helper.
+-- FilterControl/
|   +-- Entitlements.plist             # Declares the control extension's signing entitlements.
|   +-- FilterControlProvider.m        # Handles permission requests, DNS work, and activity reports.
|   +-- Makefile                       # Defines the control extension target and signing options.
|   +-- NSDomainResolver.h             # Declares the DNS resolver and injectable lookup interfaces.
|   +-- NSDomainResolver.m             # Schedules DNS lookups and handles retries and cancellation.
|   +-- NSPermissionNotifications.h    # Declares permission notification delivery interfaces.
|   +-- NSPermissionNotifications.m    # Sends, retries and withdraws notifications using current request-level policy checks.
|   +-- NSProviderWorkQueue.h          # Declares bounded work and reply queues for the provider.
|   +-- NSProviderWorkQueue.m          # Limits queued work and delivers each admitted reply once.
|   +-- Resources/
|       +-- Info.plist                 # Registers the Network Extension control provider.
+-- FilterData/
|   +-- Entitlements.plist             # Declares the data extension's signing entitlements.
|   +-- FilterDataProvider.m           # Uses shared evaluation for new/deferred flows and refreshes policy after rules change.
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
|   +-- NSConstants.h                  # Defines engine/build and schema versions, limits, and shared filenames.
|   +-- NSDNSCache.h                   # Checks DNS answer expiry and merges results into policy.
|   +-- NSDestination.h                # Validates destinations and formats hosts before direction/protocol in connection details.
|   +-- NSExport.h                     # Declares immutable import results, current JSON parsing and export staging.
|   +-- NSExport.m                     # Imports rules with 3.0.0 classifier compatibility/counts, exports raw rules/activity, and manages bounded export staging.
|   +-- NSFlowDestination.h            # Extracts hosts, ports, and protocol from iOS filter flows.
|   +-- NSGlobalRule.h                 # Declares global-condition parsing, canonical keys, overlap validation, and matching.
|   +-- NSGlobalRule.m                 # Parses CIDRs and port ranges, compiles conditions, rejects overlaps, and matches raw identities and endpoints.
|   +-- NSIdentityDisplay.h            # Formats shortened app labels and full process names from raw identities.
|   +-- NSMonitorSchema.h              # Declares validation for shared monitor snapshots.
|   +-- NSMonitorSchema.m              # Validates monitor fields, activity records, and request entries.
|   +-- NSNotificationPolicy.h         # Determines when to withdraw stale permission notifications.
|   +-- NSNotifications.h              # Registers/validates direction-aware permission actions and withdraws banners for automatic system actions.
|   +-- NSPermissionQueue.h            # Declares the queue for flows waiting on user decisions.
|   +-- NSPermissionQueue.m            # Settles held flows with shared evaluation of captured directions/peers and handles timeouts.
|   +-- NSPermissionRequest.h          # Defines canonical request fingerprints, scope, and presentation checks.
|   +-- NSPolicy.h                     # Defines raw system classification, the telemetry list interface and shared verdict APIs.
|   +-- NSPolicy.m                     # Defines the 20 telemetry identities, validates system settings and evaluates precedence for all callers.
|   +-- NSPolicyCache.h                # Declares policy caching and invalidation.
|   +-- NSPolicyCache.m                # Tracks policy file identity and caches validated snapshots.
|   +-- NSPolicyReader.h               # Declares the shared policy reader and app-group path helpers.
|   +-- NSPolicyReader.m               # Locates the app-group container and reads policy through its cache.
|   +-- NSProviderHealth.h             # Checks whether a control provider heartbeat is current.
|   +-- NSReleaseVersion.h             # Validates release versions and compares their numeric parts.
|   +-- NSRuleChoices.h                # Defines rule choices and directional selection behavior.
|   +-- NSStore.h                      # Declares shared policy, monitoring, and cleanup operations.
|   +-- NSStore.m                      # Manages shared policy/monitor/request storage, policy transactions, atomic rule imports, and request presentation validation; section choices stay in app defaults.
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
|   +-- RegressionTests.m              # Tests rules/storage/transfers, requests/notifications, switch restoration, and app preference persistence/defaults/reset.
|   +-- RespringTests.m                # Tests respring launch and fallback with a mock launcher.
|   +-- RuleFixtures.h                 # Builds current-schema rule, DNS lifetime, and permission-request test fixtures.
+-- changelog.md                       # Source history manually mirrored into depiction.json; CI extracts the matching version entry for draft notes.
+-- control                            # Defines the Debian package ID, version, and dependencies.
+-- depiction.json                     # Defines Sileo Details/header/screenshots and manually mirrored Changelog markdown; minVersion is the depiction schema.
+-- layout/
|   +-- DEBIAN/
|       +-- postinst                   # Registers the app after install and schedules a respring.
|       +-- prerm                      # Verifies filter cleanup before package removal.
+-- scripts/
    +-- bundle_metadata.mk             # Installs metadata from control/NSEngineVersion into each build bundle before signing.
    +-- check_entitlements.py          # Compares signed entitlements against the source declarations.
    +-- check_format.py                # Checks Objective-C formatting with clang-format.
    +-- check_macho.py                 # Checks Mach-O metadata and verifies embedded signature hashes.
    +-- check_signing_identity.py      # Exposes the Mach-O verifier through the identity-check CLI.
    +-- prepare_draft.cjs              # Stages and verifies package assets on a GitHub draft release.
    +-- prepare_package.py             # Prepares staged maintainer scripts for each jailbreak layout.
    +-- release_manifest.py            # Records package hashes, source revision, and toolchain versions.
    +-- sync_version.py                # Reads marketing versions from control and build versions from NSEngineVersion; generates output plists and CI metadata.
    +-- test.py                        # Compiles/runs shared, configuration, and provider regressions on macOS, then isolated respring tests; excludes UIKit.
    +-- test_macho.py                  # Tests Mach-O validation with synthetic binaries and tampering.
    +-- test_packaging.py              # Tests metadata generation, package layouts, and install scripts.
    +-- test_prepare_draft.cjs         # Tests draft staging and retries with mocked GitHub calls.
    +-- test_respring.py               # Compiles and runs the native respring tests.
    +-- test_signing_identity.py       # Exercises the wrapper with synthetic signed binaries.
    +-- validate.py                    # Checks source inputs and the extracted Debian package layout.
```

## Supporting files and local tools

| File | Role |
| --- | --- |
| `README.md` | User guide and hosted web depiction destination. |
| `LICENSE` | Project license. |
| `ProjectOverview.md` | Project file map, jailbreak package layouts, and supporting-file responsibilities. |
| `.theos-toolchain/` | Optional local SDK, clang resources, and Python syntax/format tools; excluded from shipped runtime components. |
| `scripts/check_objc.py` | Optional syntax-only iOS check using the local `.theos-toolchain` SDK and libclang. |
| `scripts/test_uninstall.py` | Standalone uninstall and deferred-respring fixtures using mock tools. |

# NetShield2

## Overview

NetShield2 is a firewall and network monitor for jailbroken iOS 15–18 devices using rootless, RootHide, or rootful packages. Apple's Network Extension content filter evaluates the browser flows that iOS delivers and, with **Filter System Sockets** enabled, the socket flows it delivers.

- The data provider uses the read-only policy reader, cache, evaluator, and bounded file access to evaluate delivered flows. It requests activity reports on allow and drop verdicts, asks the control provider for rules on permission decisions, and can defer evaluation to a data callback when endpoint information is needed.
- The control provider handles pending decisions, permission notifications and delivery retries, flow reports, and the current activation's heartbeat. It refreshes DNS-derived blocking addresses with bounded concurrency, invalidates stale results on rule or network changes, and checks expiry using wall time, elapsed time, and boot evidence where available.
- The app presents verified filter settings, rules, pending requests, and Recent Activity. Its serial storage queue handles policy edits, activity grouping, and export preparation. Activity groups distinguish transport and show mixed outcomes. Clearing activity records a generation boundary while preserving rules and pending requests. JSON export stages rules and ungrouped activity in the shared cache and protects the staged file while sharing is active.

## GitHub build and release

| Variant | `THEOS_PACKAGE_SCHEME` | Debian architecture | App path inside the extracted package |
| --- | --- | --- | --- |
| rootless | `rootless` | `iphoneos-arm64` | `var/jb/Applications/NetShield2.app` |
| RootHide | `roothide` | `iphoneos-arm64e` | `Applications/NetShield2.app` |
| rootful | empty string | `iphoneos-arm` | `Applications/NetShield2.app` |

`control` supplies the package version and the generated bundle marketing version. `NSEngineVersion` in `Shared/NSConstants.h` supplies the generated bundle build version. The packaging and source validators share helpers. `prepare_package.py` imports `sync_version.py`. `validate.py`, `test_packaging.py`, and `release_manifest.py` use both. The mocked draft test imports `prepare_draft.cjs`.

## Build and CI inputs

```text
NetShield2/
├── .clang-format                             # Sets the Objective-C formatting rules used by CI.
├── .github/
│   └── workflows/
│       └── build.yml                         # Builds all three packages, runs checks, and stages draft releases.
├── App/
│   ├── Entitlements.plist                    # Declares the app's signing entitlements.
│   ├── Makefile                              # Defines the app target, sources, frameworks, and signing options.
│   ├── NSAppDelegate.h                       # Declares the app lifecycle and notification delegate.
│   ├── NSAppDelegate.m                       # Launches the dashboard and handles notification responses.
│   ├── NSAppStorage.h                        # Declares the app's shared storage queue.
│   ├── NSAppStorage.m                        # Creates the serial queue for dashboard storage work.
│   ├── NSConfigurationCoordinator.h          # Defines the shared filter configuration transaction API.
│   ├── NSConfigurationCoordinator.m          # Serializes preference changes and tracks unfinished writes.
│   ├── NSDashboard+Configuration.m           # Captures fallback readback state and handles firewall toggles, scope, and reset.
│   ├── NSDashboard+Internal.h                # Shares dashboard state, fallback attention state, and private category methods.
│   ├── NSDashboard+Notifications.m           # Manages notification authorization and in-app permission requests.
│   ├── NSDashboard+Table.m                   # Renders concise status, conditional warnings, pending sections, search, and swipe actions.
│   ├── NSDashboard+Updates.m                 # Schedules update checks and displays available releases.
│   ├── NSDashboard.h                         # Declares the main dashboard controller.
│   ├── NSDashboard.m                         # Coordinates dashboard refreshes, rule edits, and exports.
│   ├── NSFilterBootPolicy.h                  # Declares boot fallback checks and migration helpers.
│   ├── NSFilterBootPolicy.m                  # Applies and verifies the stock-boot fallback setting.
│   ├── NSFilterRemoval.h                     # Declares verified filter removal and shared-state cleanup.
│   ├── NSFilterRemoval.m                     # Verifies preference removal before retrying shared-state cleanup.
│   ├── NSFilterRestart.h                     # Defines the filter restart interface and result states.
│   ├── NSFilterRestart.m                     # Stages, verifies, and rolls back filter restarts as needed.
│   ├── NSGlobalRuleEditor.h                  # Declares the global rule editor and its save callback.
│   ├── NSGlobalRuleEditor.m                  # Edits and validates custom rules and updates the native App dropdown.
│   ├── NSReleaseFetch.h                      # Declares the bounded release fetcher and response buffer.
│   ├── NSReleaseFetch.m                      # Streams GitHub release data with size and redirect checks.
│   ├── NSRespring.h                          # Declares the respring launcher and its test hook.
│   ├── NSRespring.m                          # Starts the jailbreak respring tool and reaps its child process.
│   ├── NSRuleActionController.h              # Declares the reusable rule and connection action controller.
│   ├── NSRuleActionController.m              # Displays rule actions, selections, and connection details and handles copying displayed values.
│   ├── NSRuleAppearance.h                    # Supplies shared colors and styles for rule actions.
│   ├── NSSectionTypography.h                 # Supplies shared text styles for table section headers.
│   ├── Resources/
│   │   ├── GitHubLogo.png                    # Provides the icon for the GitHub link.
│   │   ├── Icon.png                          # Provides the app icon and package icon asset.
│   │   ├── Info.plist                        # Provides the app bundle metadata template.
│   │   └── banner.png                        # Provides the banner used by the Sileo depiction.
│   └── main.m                                # Starts the app or runs the package uninstall helper.
├── FilterControl/
│   ├── Entitlements.plist                    # Declares the control extension's signing entitlements.
│   ├── FilterControlProvider.m               # Handles permission requests, DNS work, and activity reports.
│   ├── Makefile                              # Defines the control extension target and signing options.
│   ├── NSDomainResolver.h                    # Declares the DNS resolver and injectable lookup interfaces.
│   ├── NSDomainResolver.m                    # Schedules DNS lookups and handles retries and cancellation.
│   ├── NSPermissionNotifications.h           # Declares permission notification delivery interfaces.
│   ├── NSPermissionNotifications.m           # Sends, retries, and withdraws permission notifications.
│   ├── NSProviderWorkQueue.h                 # Declares bounded work and reply queues for the provider.
│   ├── NSProviderWorkQueue.m                 # Limits queued work and delivers each admitted reply once.
│   └── Resources/
│       └── Info.plist                        # Registers the Network Extension control provider.
├── FilterData/
│   ├── Entitlements.plist                    # Declares the data extension's signing entitlements.
│   ├── FilterDataProvider.m                  # Evaluates flows against policy and returns iOS filter verdicts.
│   ├── Makefile                              # Defines the data extension target and signing options.
│   └── Resources/
│       └── Info.plist                        # Registers the Network Extension data provider.
├── Makefile                                  # Builds all three targets and runs the Debian packaging hooks.
├── Shared/
│   ├── NSActivity.h                          # Groups activity and shares connection-sheet, search, and clipboard details.
│   ├── NSAppPreferences.h                    # Defines update-check preferences and app preference reset helpers.
│   ├── NSBootSession.h                       # Looks up the current system boot identity when available.
│   ├── NSBoundedFile.h                       # Declares bounded file reads, writes, and removal.
│   ├── NSBoundedFile.m                       # Checks file descriptors and performs bounded I/O and atomic writes.
│   ├── NSConstants.h                         # Defines engine/build and schema versions, limits, and shared filenames.
│   ├── NSDNSCache.h                          # Checks DNS answer expiry and merges results into policy.
│   ├── NSDestination.h                       # Validates destinations and formats hosts before direction/protocol in connection details.
│   ├── NSExport.h                            # Declares JSON export and temporary file staging helpers.
│   ├── NSExport.m                            # Builds JSON exports and manages the lifetime of staged files.
│   ├── NSFlowDestination.h                   # Extracts hosts, ports, and protocol from iOS filter flows.
│   ├── NSGlobalRule.h                        # Parses and normalizes global rule conditions and keys.
│   ├── NSIdentityDisplay.h                   # Formats shortened app labels and full process names from raw identities.
│   ├── NSMonitorSchema.h                     # Declares validation for shared monitor snapshots.
│   ├── NSMonitorSchema.m                     # Validates monitor fields, activity records, and request entries.
│   ├── NSNotificationPolicy.h                # Determines when to withdraw stale permission notifications.
│   ├── NSNotifications.h                     # Defines permission notification categories and actions.
│   ├── NSPermissionQueue.h                   # Declares the queue for flows waiting on user decisions.
│   ├── NSPermissionQueue.m                   # Tracks pending flows, timeouts, and completed decisions.
│   ├── NSPolicy.h                            # Defines the policy interface, flow directions, and verdict types.
│   ├── NSPolicy.m                            # Validates rules and shares protocol matching, endpoint acquisition, and flow decisions.
│   ├── NSPolicyCache.h                       # Declares policy caching and invalidation.
│   ├── NSPolicyCache.m                       # Tracks policy file identity and caches validated snapshots.
│   ├── NSPolicyReader.h                      # Declares the shared policy reader and app-group path helpers.
│   ├── NSPolicyReader.m                      # Locates the app-group container and reads policy through its cache.
│   ├── NSProviderHealth.h                    # Checks whether a control provider heartbeat is current.
│   ├── NSReleaseVersion.h                    # Validates release versions and compares their numeric parts.
│   ├── NSRuleChoices.h                       # Defines rule choices and directional selection behavior.
│   ├── NSStore.h                             # Declares shared policy, monitoring, and cleanup operations.
│   ├── NSStore.m                             # Persists rules and monitor data, applies decisions, and clears state.
│   ├── NSConfigurationRecord.h               # Defines record admission, immutable tokens, and execution hooks.
│   ├── NSConfigurationRecord.m               # Validates records and bounds physical locking.
│   ├── NSStoreLock.h                         # Declares the shared filesystem lock.
│   ├── NSStoreLock.m                         # Acquires and releases locks across the app and providers.
│   └── NSValidation.h                        # Validates stored strings, Boolean values, and unsigned integers.
├── Tests/
│   ├── BootPolicyTests.m                     # Tests boot fallback settings, preference readback, and recovery.
│   ├── ConfigurationTests.m                  # Tests preference transaction timeouts and pending writes.
│   ├── HardeningTests.m                      # Tests bounded I/O, DNS, reply queues, and activity safety.
│   ├── RecoveryTests.m                       # Tests DNS recovery, notification retries, and activity clearing.
│   ├── RegressionTests.m                     # Tests rule matching, process-name formatting, requests, storage, and exports.
│   └── RespringTests.m                       # Tests respring launch and fallback with a mock launcher.
├── changelog.md                              # Supplies versioned notes for the GitHub draft release.
├── control                                   # Defines the Debian package ID, version, and dependencies.
├── depiction.json                            # Defines the package presentation in Sileo.
├── layout/
│   └── DEBIAN/
│       ├── postinst                          # Registers the app after install and schedules a respring.
│       └── prerm                             # Verifies filter cleanup before package removal.
└── scripts/
    ├── bundle_metadata.mk                    # Generates each bundle's versioned Info.plist before signing.
    ├── check_entitlements.py                 # Compares signed entitlements against the source declarations.
    ├── check_format.py                       # Checks Objective-C formatting with clang-format.
    ├── check_macho.py                        # Checks Mach-O metadata and verifies embedded signature hashes.
    ├── check_signing_identity.py             # Exposes the Mach-O verifier through the identity-check CLI.
    ├── prepare_draft.cjs                     # Stages and verifies package assets on a GitHub draft release.
    ├── prepare_package.py                    # Prepares staged maintainer scripts for each jailbreak layout.
    ├── release_manifest.py                   # Records package hashes, source revision, and toolchain versions.
    ├── sync_version.py                       # Reads the package version and generates build metadata.
    ├── test.py                               # Compiles and runs native Objective-C regressions on macOS.
    ├── test_macho.py                         # Tests Mach-O validation with synthetic binaries and tampering.
    ├── test_packaging.py                     # Tests metadata generation, package layouts, and install scripts.
    ├── test_prepare_draft.cjs                # Tests draft staging and retries with mocked GitHub calls.
    ├── test_respring.py                      # Compiles and runs the native respring tests.
    ├── test_signing_identity.py              # Exercises the wrapper with synthetic signed binaries.
    └── validate.py                           # Checks source inputs and the extracted Debian package layout.
```

## Supporting files and local tools

| File | Role |
| --- | --- |
| `README.md` | User guide and hosted web depiction destination. |
| `ProjectOverview.md` | Project architecture and build inputs. |
| `LICENSE` | Project license. |
| `scripts/check_objc.py` | Optional syntax-only iOS check using the local `.theos-toolchain` SDK and libclang. |
| `scripts/test_uninstall.py` | Standalone uninstall and deferred-respring fixtures using mock tools. |

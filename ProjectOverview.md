# NetShield2

## Overview

NetShield2 is a firewall and network monitor for jailbroken iOS 15–18 devices using rootless, RootHide, or rootful packages. Apple's Network Extension content filter evaluates the browser flows that iOS delivers and, with **Filter System Sockets** enabled, the socket flows it delivers.

- The data provider uses the read-only policy reader, cache, evaluator, and bounded file access to evaluate delivered flows. It returns allow, drop, or a request for rules from the control provider, and requests reports for activity tracking.
- The control provider handles pending decisions, permission notifications and delivery retries, flow reports, and the current activation's heartbeat. It refreshes DNS-derived blocking addresses with bounded concurrency, invalidates stale results on rule or network changes, and checks expiry using wall time, elapsed time, and boot evidence where available.
- The app presents verified filter settings, rules, pending requests, and Recent Activity. Its serial storage queue handles policy edits, activity grouping, and export preparation. Activity groups distinguish transport and show mixed outcomes. Clearing activity records a generation boundary while preserving rules and pending requests. JSON export stages recorded events before grouping in the shared cache and protects files while sharing is active.

The app and providers use an iOS app-group container. Bounded, descriptor-based file access, typed validation, atomic writes, and shared locks protect policy and monitor data. The data provider reads policy without linking the shared store's write and cleanup code.

## Firewall setup and recovery

One explicit On action starts setup. The app proceeds after the notification permission response, including denial. The restart checks fresh preferences against the dashboard's saved baseline, verifies an independent copy of the candidate and its boot fallback, saves it Off, and verifies that saved profile before saving it On. After verifying the enabled profile, it waits for the current activation's control heartbeat. The switch follows verified saved preferences, with separate status for setup progress and control health. Checking enforcement requires a new connection against a known rule.

During an authorization save, foreground and preference-change signals queue a refresh. The coordinator waits for the save callback or uses a final bounded receipt probe after the 60-second authorization wait. This keeps an early receipt load from ending setup during consent. Each save has a unique receipt and only a fresh persisted load can prove a save by receipt. A callback arriving during the final probe waits for the probe to drain before the transaction can advance. Ordinary preference operations and provider startup retain their own deadlines.

A cross-process configuration lock and durable pending-write record protect against overlapping app and removal operations. A timed-out read reserves the mutable manager until its callback drains or the app process restarts. An unresolved write retains its durable record across relaunch. Late callbacks and receipt proof can reconcile ownership without resuming an expired intent. Cleanup and rollback check that the loaded profile still belongs to the transaction. Reset verifies the filter is disabled before clearing shared state. **Remove Filter & Settings** and uninstall verify absence before cleanup.

Launch, foreground entry, preference changes, and late completion drive saved-state reconciliation. Tap **Firewall status** to refresh manually. Follow the dashboard's recovery guidance if a read or write remains unresolved. If an updated content filter still shows Invalid after refreshing and explicitly retrying, a full reboot and re-jailbreak may be needed.

### Stock-boot fallback

When a provider is active and cannot load valid policy, its filtering path blocks affected flows. For a stock boot where jailbreak providers are unavailable, NetShield2 applies and reads back the private `disableDefaultDrop` property to request the system's connectivity fallback. The copy and persisted readback checks are part of activation. Stock-boot connectivity and rule enforcement need device testing on the target iOS and jailbreak combinations.

## GitHub build and release

GitHub Actions builds all three `.deb` variants. The matrix runs on `macos-15`, installs `make`, `ldid`, `xz`, and `dpkg` via Homebrew, checks out pinned Theos revisions (`theos/theos` for rootless and rootful, `roothide/theos` for RootHide), and verifies the downloaded iOS 16.5 SDK against the workflow's SHA-256. The top-level `Makefile` sets `arm64` and an iOS 15.0 deployment target for each variant. The Debian architecture labels describe the package schemes. [Build workflow](.github/workflows/build.yml)

| Variant | `THEOS_PACKAGE_SCHEME` | Debian architecture | App path inside the extracted package |
| --- | --- | --- | --- |
| rootless | `rootless` | `iphoneos-arm64` | `var/jb/Applications/NetShield2.app` |
| RootHide | `roothide` | `iphoneos-arm64e` | `Applications/NetShield2.app` |
| rootful | empty string | `iphoneos-arm` | `Applications/NetShield2.app` |

1. CI reads the package ID and release version from `control`, validates source inputs, runs the Python metadata and signature fixtures and the Node draft-release fixtures, checks maintainer-script syntax, and checks Objective-C formatting with clang-format 19.1.7.
2. The native suite compiles and runs on macOS using `xcrun` and the Xcode tools. It exercises the app's configuration, boot-policy, removal, and release-fetch code, the control provider's DNS, notification, and work-queue helpers, and the shared policy, store, lock, export, and permission-queue code. The runner also invokes `scripts/test_respring.py` with `App/NSRespring.m`. The rootless job additionally runs the shared-code suite with ASan and UBSan. The two runners' source lists define the test link inputs.
3. Theos builds one app and two Network Extension bundles into each `.deb`. Before signing, `scripts/bundle_metadata.mk` calls `scripts/sync_version.py` to generate the three staged `Info.plist` files from their source templates. `CFBundleShortVersionString` comes from `control` (`2.7.1`), and `CFBundleVersion` comes from `NSEngineVersion` (`20047`) in `Shared/NSConstants.h`. Leave both keys out of the source templates. The root Makefile runs `scripts/prepare_package.py` to stamp the version and adapt `postinst` and `prerm` for the selected layout.
4. CI extracts the finished `.deb` with `dpkg-deb` and validates its layout, metadata, and maintainer scripts. It checks the actual packaged app and extension binaries by reading Theos/ldid Mach-O CodeDirectories, and extracts and checks each binary's signed entitlements with `ldid -e`. `scripts/check_signing_identity.py` is a wrapper around the Mach-O verifier. Its tests use synthetic signed binaries from `scripts/test_macho.py`.
5. Each job uploads its renamed `.deb` and an internal provenance manifest recording the source revision, package hash, and toolchain. After all three jobs succeed on a push to `main`, the release job uses the matching section in `changelog.md` and checks the three packages and manifests against the source revision and expected hashes. It verifies staged uploads before leaving exactly three final `.deb` assets in an unpublished draft. Pull requests and manual workflow runs stop after the build jobs.

```text
com.eolnmsuk.netshield_2.7.1_rootless.deb
com.eolnmsuk.netshield_2.7.1_roothide.deb
com.eolnmsuk.netshield_2.7.1_rootful.deb
```

The packaging and source validators share helpers. `prepare_package.py` imports `sync_version.py`. `validate.py`, `test_packaging.py`, and `release_manifest.py` use both. The mocked draft test imports `prepare_draft.cjs`.

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
│   ├── NSDashboard+Configuration.m           # Handles firewall toggles, socket scope, and settings reset.
│   ├── NSDashboard+Internal.h                # Shares private dashboard state and methods across categories.
│   ├── NSDashboard+Notifications.m           # Manages notification authorization and in-app permission requests.
│   ├── NSDashboard+Table.m                   # Renders dashboard rows, activity search, and swipe actions.
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
│   ├── NSGlobalRuleEditor.m                  # Edits global rule conditions and validates entries before saving.
│   ├── NSReleaseFetch.h                      # Declares the bounded release fetcher and response buffer.
│   ├── NSReleaseFetch.m                      # Streams GitHub release data with size and redirect checks.
│   ├── NSRespring.h                          # Declares the respring launcher and its test hook.
│   ├── NSRespring.m                          # Starts the jailbreak respring tool and reaps its child process.
│   ├── NSRuleActionController.h              # Declares the reusable rule and connection action controller.
│   ├── NSRuleActionController.m              # Displays rule actions, selections, and connection details.
│   ├── NSRuleAppearance.h                    # Supplies shared colors and styles for rule actions.
│   ├── NSSectionTypography.h                 # Supplies shared text styles for table section headers.
│   ├── Resources/
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
│   ├── NSActivity.h                          # Groups activity records and formats connection details.
│   ├── NSAppPreferences.h                    # Defines update-check preferences and app preference reset helpers.
│   ├── NSBootSession.h                       # Looks up the current system boot identity when available.
│   ├── NSBoundedFile.h                       # Declares bounded file reads, writes, and removal.
│   ├── NSBoundedFile.m                       # Checks file descriptors and performs bounded I/O and atomic writes.
│   ├── NSConstants.h                         # Defines engine and schema versions, limits, and shared filenames.
│   ├── NSDNSCache.h                          # Checks DNS answer expiry and merges results into policy.
│   ├── NSDestination.h                       # Validates and formats network endpoint details.
│   ├── NSExport.h                            # Declares JSON export and temporary file staging helpers.
│   ├── NSExport.m                            # Builds JSON exports and manages the lifetime of staged files.
│   ├── NSFlowDestination.h                   # Extracts hosts, ports, and protocol from iOS filter flows.
│   ├── NSGlobalRule.h                        # Parses and normalizes global rule conditions and keys.
│   ├── NSIdentityDisplay.h                   # Formats app and process identities for display.
│   ├── NSMonitorSchema.h                     # Declares validation for shared monitor snapshots.
│   ├── NSMonitorSchema.m                     # Validates monitor fields, activity records, and request entries.
│   ├── NSNotificationPolicy.h                # Determines when to withdraw stale permission notifications.
│   ├── NSNotifications.h                     # Defines permission notification categories and actions.
│   ├── NSPermissionQueue.h                   # Declares the queue for flows waiting on user decisions.
│   ├── NSPermissionQueue.m                   # Tracks pending flows, timeouts, and completed decisions.
│   ├── NSPolicy.h                            # Defines the policy interface, flow directions, and verdict types.
│   ├── NSPolicy.m                            # Validates rule documents and evaluates policy for each flow.
│   ├── NSPolicyCache.h                       # Declares policy caching and invalidation.
│   ├── NSPolicyCache.m                       # Tracks policy file identity and caches validated snapshots.
│   ├── NSPolicyReader.h                      # Declares the shared policy reader and app-group path helpers.
│   ├── NSPolicyReader.m                      # Locates the app-group container and reads policy through its cache.
│   ├── NSProviderHealth.h                    # Checks whether a control provider heartbeat is current.
│   ├── NSReleaseVersion.h                    # Validates release versions and compares their numeric parts.
│   ├── NSRuleChoices.h                       # Defines rule choices and directional selection behavior.
│   ├── NSStore.h                             # Declares shared policy, monitoring, and cleanup operations.
│   ├── NSStore.m                             # Persists rules and monitor data, applies decisions, and clears state.
│   ├── NSStoreLock.h                         # Declares the shared filesystem lock.
│   ├── NSStoreLock.m                         # Acquires and releases locks across the app and providers.
│   └── NSValidation.h                        # Validates stored strings, Boolean values, and unsigned integers.
├── Tests/
│   ├── BootPolicyTests.m                     # Tests boot fallback settings, preference readback, and recovery.
│   ├── ConfigurationTests.m                  # Tests preference transaction timeouts and pending writes.
│   ├── HardeningTests.m                      # Tests bounded I/O, DNS, reply queues, and activity safety.
│   ├── RecoveryTests.m                       # Tests DNS recovery, notification retries, and activity clearing.
│   ├── RegressionTests.m                     # Runs core regressions for rules, requests, storage, and exports.
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
| `screenshots/1.PNG` through `screenshots/5.PNG`, `screenshots/ALL.PNG` | Presentation images. |
| `scripts/check_objc.py` | Optional syntax-only iOS check using the local `.theos-toolchain` SDK and libclang. |
| `scripts/test_uninstall.py` | Standalone uninstall and deferred-respring fixtures using mock tools. |

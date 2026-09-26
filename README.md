# NetShield 2

**Experimental OS content filter and flow monitor for rootless iOS 16.**

This replaces the v1 injected socket hooks with a standalone app and two Network Extension providers. The intended test device is **iOS 16.1.1 / Dopamine 3.0.10**. Its supervision status is unknown. **Supported deployment on that device has not been established. This is not a finished all-traffic firewall.**

The providers implement real OS flow verdicts, but source code and a successful `.deb` build do not prove that iOS will register, authorize or run them. No device or GitHub runner was available during the initial rewrite. Treat `2.0.0~alpha1` as a deployment experiment.

## Build with GitHub Actions

Put the contents of this folder at the root of your GitHub repository. Run **Actions > Build NetShield 2 experimental > Run workflow**, or push a commit. The macOS job installs a pinned Theos revision, verifies the iOS 16.5 SDK checksum, runs policy and packaging tests, compiles the app/providers and uploads:

`NetShield-2-experimental-iOS16-rootless` containing `com.eolnmsuk.netshield_2.0.0~alpha1_iphoneos-arm64.deb`.

No repository, remote or GitHub authentication is configured in this copied workspace; the workflow has not been dispatched. A local Mac with Theos and the 16.5 SDK can run `make package FINALPACKAGE=1`. Apps and extensions use arm64, which also runs on arm64e devices; no arm64e injected system library is built.

## Deployment is the first acceptance gate

Apple's supported system-wide content-filter path on iOS requires supervision, with a separate Family Controls child-device authorization path. iOS 16 individual Screen Time authorization is insufficient. Per-app managed-device filtering is not an equivalent system-wide deployment.

The included entitlement declarations and rootless app registration are **experimental jailbreak packaging**, not an Apple provisioning profile and not a verified Dopamine entitlement bypass. Supervision alone also does not prove these ad-hoc signed providers will launch. This package does not spoof supervision, patch `nehelper`/`nesessionmanager`, or alter kernel trust policy.

1. Determine whether Settings displays a supervision message. Record device model, OS build and Dopamine version.
2. Install the experimental deb. `postinst` registers `/var/jb/Applications/NetShield.app` with `uicache`; this requests registration but does not validate PlugInKit or NE authorization.
3. If upgrading v1, reboot and re-jailbreak to unload its old hooks from already-running processes. The v2 package contains no injection dylib or Preferences pane.
4. Open **NetShield** from the Home Screen. Confirm app-group storage is available. Defaults allow attributed and unattributed flows; the filter is initially disabled.
5. Enable the filter. This may replace another app's active content filter. Any OS error is displayed with its domain and code. A successful save is shown only as a saved configuration.
6. Generate new traffic. Confirm a recent control-provider heartbeat and actual OS flow reports. Neither proves comprehensive coverage; execute [the device tests](Tests/DEVICE_TESTS.md).

If the OS denies the configuration or never launches the providers, stop at that gate. The missing work is a demonstrated deployment method for this target, not more socket hooks. There is no automatic fallback that silently presents partial filtering as protection.

## Rules and monitoring

- Tap an observed OS identity to allow/block it or block initially inbound/outbound flows. Exact `sourceAppIdentifier` values are preserved. Do not assume they equal bundle IDs or remove signing prefixes.
- Unidentified flows have an explicit allow/block policy. Blocking them can break system services. Shared-daemon attribution is whatever iOS supplies; NetShield does not invent an originating app.
- Rules apply at **new-flow admission**. Already-admitted flows retain their verdict until closed. Inbound means a flow initiated toward the device, not responses on an outbound connection. Reconnect after rule changes.
- Invalid/unreadable policy blocks new flows **while a running data provider receives callbacks**. Provider startup errors, crashes, disabled filtering, OS bypasses and pre-jailbreak boot traffic have no fail-closed guarantee.
- The monitor keeps at most 300 flow reports per control-provider session. Byte totals are supplied at flow close, not continuously. It records no payloads, URLs or destinations. Reports are delayed and may be absent; the display is not a packet capture.
- No automatic import of v1 rules: the old app-derived identities and direction semantics are incompatible. v1 preferences on the device are ignored.

## Coverage boundary

Both `filterSockets` and `filterBrowsers` are requested. Filtering acts on flows the OS delivers, regardless of whether the source app has tweak injection. TCP/UDP, IPv4/IPv6, QUIC, background sessions, shared helpers and daemon attribution still require measured device tests. Raw IP, ICMP, kernel traffic, loopback, VPN interactions and OS-exempt paths are **not claimed covered**. iOS 16 exposes neither `NEFilterPacketProvider` nor the public flow process-audit-token APIs available on macOS.

Before uninstalling, use **Remove filter configuration**, confirm the saved configuration is disabled and verify connectivity. The removal script unregisters the app; it does not independently prove that the OS removed a lingering NE configuration. If removal was premature, reinstall the app and remove its configuration through the UI. Device restart/re-jailbreak and recovery behavior are acceptance tests, not assumed guarantees.

## Source layout and verification

| Path | Responsibility |
| --- | --- |
| `App/` | UIKit dashboard, NE configuration, policy editing, truthful status |
| `FilterData/` | Sandboxed OS flow decisions; reads atomic policy snapshots |
| `FilterControl/` | OS reports, bounded metadata history, control heartbeat |
| `Shared/` | Validated immutable policy, app-group storage |
| `layout/DEBIAN/` | Rootless registration/removal scripts |
| `Tests/`, `scripts/` | Policy tests, packaging checks, device acceptance procedure |
| `.github/workflows/build.yml` | Theos build and experimental deb artifact |

`python scripts/validate.py` and `python Tests/validation_test.py` run without third-party Python packages. Objective-C policy tests need macOS Foundation and run in CI. A package build validates Mach-O architecture, embedded extension metadata, signed entitlements and absence of old injection artifacts. These checks cannot establish OS acceptance or runtime coverage.

## Primary references

- [Apple: Network Extension provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
- [Apple engineer: iOS 16 individual authorization does not enable content filters](https://developer.apple.com/forums/thread/715226)
- [Apple: source app identity](https://developer.apple.com/documentation/networkextension/nefilterflow/sourceappidentifier)
- [Apple: content-filter provider model](https://developer.apple.com/documentation/networkextension/nefilterprovider)
- [Theos: rootless packaging](https://theos.dev/docs/rootless)
- [Dopamine releases](https://github.com/opa334/Dopamine/releases)

MIT License. Copyright 2026 EolnMsuk.

# NetShield 2 device acceptance

Status: **Alpha 1 deployment failed on-device**. Owner confirms build, installation and Home Screen app launch. Filter configuration remains disabled with `NEFilterErrorDomain 5`, absent/stale control heartbeat and no flow reports. Target: **iOS 16.1.1 / Dopamine 3.0.10**; device model, OS build and supervision unknown. Coverage tests below remain NOT RUN.

Alpha 2 tests Apple's documented development configuration exception by adding `get-task-allow` to the containing app. It also labels each failed filter-manager operation. Record whether this changes configuration access and, separately, whether both providers run. This is not a verified production deployment method. A passing GitHub build is not device qualification.

## 1. Deployment gate

Record model, OS build, jailbreak version, supervision status, existing VPN/filter configuration, deb SHA-256 and GitHub workflow URL. Use a test network with a second computer as an independent traffic observer. Keep local device access for recovery.

1. Build the workflow and confirm all three executables have the expected signed entitlements. Install through the package manager.
2. On a v1 upgrade, reboot and re-jailbreak before testing. Verify the old NetShield dylib and PreferenceLoader files are absent. Processes can retain deleted dylibs until they exit.
3. Confirm the Home Screen app launches and can save policy in the shared app-group container. Do not substitute a world-writable global preferences file when container authorization fails.
4. Enable filtering and record the exact error domain/code, if any. Verify both extension bundle IDs are registered and that their `startFilterWithCompletionHandler:` callbacks succeed, using device logs/debugging tools. Neither uicache's success nor a manager save proves this.
5. Confirm the monitor's control heartbeat updates. Create a new connection and verify the **OS** produces a matching new-flow report; this proves more than the control heartbeat alone. Reports must change as traffic is generated, not merely show an old session.
6. With default block, show a new connection fails at a separately observed peer; restore allow and show a new connection succeeds. This is a functional filter check, not just a dashboard check.

**Stop if any deployment step fails.** A permission error or an unlaunched provider means no verified protection. Supervision may be necessary for the supported deployment path; the ad-hoc entitlement and app-group acceptance of this rootless package also require validation. Do not claim Dopamine support without recorded results. The package intentionally contains no supervision spoof or unverified NE authorization hook.

## 2. Attribution and coverage matrix

For every case below record: source app/process, reported exact identity (or empty), protocol, address family, interface, expected decision, observed verdict and independent peer result. Test both allow and block on **fresh** connections. Do not infer an app identity from a PID or the executable name. Where iOS reports a helper or nothing, preserve that fact and test the unattributed policy separately.

| Case | Required variants | Result |
| --- | --- | --- |
| Foreground browser | WebKit navigation and non-browser sockets | NOT RUN |
| Ordinary application | NSURLSession and Network.framework | NOT RUN |
| Injection disabled | Same app, same destination, new connections | NOT RUN |
| Independent CLI client | Non-injected TCP and UDP sockets | NOT RUN |
| Address family | IPv4 and IPv6, including IPv6-only network | NOT RUN |
| Transport | TCP, UDP, QUIC/HTTP3; disable fallback to TCP for QUIC test | NOT RUN |
| Interface | Wi-Fi, cellular, interface transition | NOT RUN |
| Background transfers | Background URLSession after app termination | NOT RUN |
| Shared helpers | nsurlsessiond and another app using the same helper | NOT RUN |
| System services | At least one independently verified daemon flow | NOT RUN |
| DNS | System resolver and app-operated resolver; attribution may be unavailable | NOT RUN |
| Incoming flow | IPv4/IPv6 listening socket reached by LAN peer | NOT RUN |
| Established flows | Keep a connection alive, change its rule, then reconnect | Expected: old admission persists; new flow obeys rule |
| Missing attribution | Allow and block unknown while attributed apps have opposite rules | NOT RUN |
| VPN | No VPN, full tunnel, tunnel restart | NOT RUN |
| OS exceptions | Loopback, raw IP/ICMP, kernel/exempt paths | Not claimed covered; record observed exclusions |

Use unique peer ports or request tokens to correlate tests; the dashboard deliberately omits destinations. For CLI tests, use available device TCP/UDP tools against a controlled server. A closed server port or missing route is not evidence of blocking: establish a successful allow baseline first. Include IPv6 explicitly; IPv4 success says nothing about IPv6. Incoming tests concern externally initiated flows, not replies to outgoing traffic.

## 3. Rule and report correctness

1. Observe two apps. Block one exact identity while allowing the other; repeat with injection disabled. Ensure no prefix normalization causes identities to merge.
2. Test default block + explicit allow, and default allow + explicit block. Exercise unattributed flow policy independently.
3. Test inbound/outbound flow rules. Unknown initial direction must be denied for a directional rule.
4. Keep a connection open across a rule edit: the current implementation intentionally does not revoke an admitted flow. Reconnect and confirm the new verdict. Never describe this version as an immediate kill switch.
5. While the provider is running, corrupt or make the policy unreadable in a controlled test, then attempt new flows. Confirm callbacks deny instead of using stale allow rules. Restore a valid atomic snapshot. Separately test missing policy at provider startup: that is a startup error, not guaranteed system-wide fail-closed behavior.
6. Confirm new-flow and flow-close reports, direction and final byte counts. Generate over 300 reports; memory and the on-disk monitor must remain bounded. Close the UI and confirm providers continue operating.
7. Confirm no payload, URL or destination is persisted. Verify provider/app group file access while locked and after a reboot's first unlock.

## 4. Lifecycle, failure and recovery

- Force-stop each provider separately and observe traffic independently. Record whether the OS drops, bypasses or restarts; no crash-time protection guarantee is assumed.
- Stop the control provider: the heartbeat must become stale within eight seconds. An old flow timestamp must not be presented as current protection.
- Activate another content filter and return to NetShield: the saved enabled state must refresh.
- Disable/remove configuration in the app, reconnect and verify access. Uninstall, reinstall and check for orphaned NE configuration and stale history. The uninstall script unregisters the app but does not itself call NEFilterManager.
- Test a userspace reboot, full reboot, re-jailbreak, locked device and loss of the jailbreak. Record unprotected intervals. No pre-jailbreak/boot coverage is claimed.
- Benchmark repeated new connections, long transfers, battery use and memory with the filter enabled/disabled. The data provider reads a bounded policy file per new flow; quantify this admission cost before optimizing it.

If an enabled configuration survives an unsuccessful uninstall, reinstall the same app and use **Remove filter configuration**. Confirm recovery using the peer. Do not rely on rebooting as a documented configuration-removal method.

## Release decision

Promotion beyond alpha requires evidence that registration, authorization, app groups, both provider lifecycles, app attribution and each claimed coverage case work on the exact target. Unknown or failing cases remain exclusions. Literal all-network-activity coverage, guaranteed attribution of every system flow and supported unsupervised Dopamine deployment remain **unmet requirements** in this version.

# NetShield2 2.6.8 behavior and evidence guide

Updated November 3, 2026. Package version **2.6.8**, engine/build **20046**, rules schema **3**, monitor schema **2**.
This is local release preparation; publication remains manual. The historical 2.6.2
observations below remain attributed to those packages. Stable branding does not
establish wider compatibility or filtering in the non-jailbroken state.

## Included behavior

All RootHide, rootless and rootful builds include the guarded fallback policy.
Every new or restored configuration must retain the actual private
`disableDefaultDrop = YES` property, in both socket scopes. The app checks getter
and setter availability and Boolean signatures, uses typed access with exception
handling, and verifies setter readback, independent copies and preference reloads.
There is no opt-in build mode or successful activation that silently omits it.
Unsupported or failed runtime configurations produce explicit local errors.

The intended fallback allows all traffic without NetShield2 blocking or monitoring
while providers are unavailable. Saved rules remain and should resume when filtering
returns; resumed blocking was reported on the setup below. This does not selectively
enforce saved rules in stock mode. Provider-unavailability windows outside stock boot
may also permit traffic. Connections opened during fallback may not be reclassified
when filtering returns; `preserveExistingConnections` is unchanged.

The data/control NetworkExtension architecture is preserved. There is no injection,
VPN/proxy replacement, stock-boot helper, shutdown hook or dependency on a
jailbreak-only daemon after stock boot. Only NetShield2's own configuration is edited;
there are no broad preference edits, unrelated-profile removals, guessed keys,
vendor-metadata substitutes for the property or blind KVC.

## Accepted user-reported evidence

These observations are attributed to the user and were **not independently
reproduced** during local preparation.

| Item | Accepted report |
| --- | --- |
| Exact setup | **iPhone 13 mini; iOS 16.1.1 (20B101); Dopamine-roothide v3.0.12-29**. |
| Package and launch | Installed the **RootHide experimental 2.6.2** package and opened NetShield2 while jailbroken. |
| Jailbroken enforcement | **Allow → Block → Allow** blocked and restored the tested app's connection. |
| Ordinary stock boot | Full reboot/shutdown into the non-jailbroken state with **Firewall ON**, **Filter System Sockets ON** and rules set preserved immediate internet access, without perceived delay or failures. |
| Forced restart | The same immediate connectivity in the non-jailbroken state, without perceived lag. |
| Return to jailbreak | Apps with saved **Block** rules were blocked again after re-jailbreaking. |
| App reporting | Candidate-policy preference readback, a responding control provider, and browser/socket filtering configured continued to be reported. |

A subsequent user report covers a newly built **standard 2.6.2 BETA** package on
**RootHide, iOS 16.1.1, Dopamine 3**: the previous version was uninstalled, the beta
was installed, Firewall and Filter System Sockets were enabled, and firewall
enforcement worked. The footer reported the beta policy read back from preferences.
Internet access worked after a stock reboot, and firewall enforcement worked again
after re-jailbreaking. This report is separate from the experimental-package record
above; it does not add a forced-restart result or establish behavior on rootless.

The app reports three separate facts: the actual saved policy value read back from
preferences, the configured browser/socket scope, and current-activation control
health. A control heartbeat does not establish data-provider enforcement, every
flow's disposition or provider state during an earlier stock boot. App-side reports
after returning to jailbreak are not stock-side captures.

## Fallback limitations

- The supplied behavioral evidence covers only the exact setup above. Three package
  variants do not establish universal iOS 15–18, jailbreak or package compatibility.
- Stock-side enabled/flag/provider state was not independently captured. Connectivity
  alone does not establish provider absence, the precise OS failure mechanism or
  universal fallback semantics.
- No matched comparison isolates the private property from the accompanying
  restart/migration changes. The property alone is not proved necessary or sufficient.
- Exact cycle counts, package hash/source revision, app/endpoints and interface or
  protocol coverage were not supplied. “Immediate” and “no perceived lag” are user
  impressions, not measured latency.
- Pre-unlock behavior, wider browser/system/protocol coverage, startup/crash exposure
  and treatment of connections opened during fallback are unmeasured.
- Runtime method support, copy retention and preference persistence can vary. Runtime
  failures remain explicit even though all three package variants are prepared.

These limits describe the historical observations. The hardening candidate still
needs the native and device checks in the [implementation record](hardening-implementation.md).

## Icon-cache and notification limitation

The user reports TrollStore **2.1.1**, with NetShield2 installed only from its
jailbreak `.deb`, not a TrollStore IPA. While jailbroken, rebuilding the icon cache
leaves **Firewall ON** but resets/removes notification permission. With Default Rule
set to Ask Me, new apps can consequently be blocked without notification banners.
The existing manual Firewall re-enable was reported to request permission again;
this is not a new recovery feature.

The separate non-jailbroken report says the rebuild turns the Firewall toggle
**OFF**; the exact saved NetworkExtension state has not been independently inspected.
The user reports working stock-state internet on **2.6.2**, including after a rebuild.
Older versions reportedly regained some internet after a rebuild while cellular
remained SOS; that is not an established recovery method or a current 2.6.2 regression.

TrollStore 2.1.1's [root helper](https://github.com/opa334/TrollStore/blob/2.1.1/RootHelper/main.m#L1453-L1460)
rebuilds LaunchServices databases and refreshes registrations. Its permission-preserving
registration step remains disabled because it moved home-screen icons. The
[maintainer discussion](https://github.com/opa334/TrollStore/issues/372) documents the
notification reset and reverted workaround, with later TrollStore 2 reports. This
supports a registration-related explanation; it does not prove the cause of the
separate stock-state filter change.

No supported NetShield2-only preventive fix was identified for preserving these
OS-managed states during an external rebuild while the app is closed. This remains
a known limitation. Notification authorization, the saved-state Firewall
switch and Ask Me behavior remain unchanged. No detection, polling, automatic
recovery or special-case UI is added. The stock-boot fallback remains in all three
variants; its private NetworkExtension property is separate from icon registration
and notification authorization.

## Migration and recovery

Install the matching variant with Sileo or Zebra **while jailbroken**, allow the
existing automatic respring to finish, then **open NetShield2**. Installation and
respring alone do not update the saved NetworkExtension configuration. An enabled
configuration is checked on app load for a missing/unreadable/false actual policy,
even at the current engine 20046, as well as an older engine, socket-scope mismatch
or description mismatch. An enabled configuration from an older engine is eligible
for the guarded restart on launch when preferences, policy and recovery state allow
it. A disabled configuration migrates on the next enable. An already current, migrated configuration
does not restart merely because of stable release wording.

Automatic migration retains the per-launch guard and durable
`NSBootPolicyAutomaticAttempts` claims. The unchanged target is
`boot-policy-1/<OS version-build string>/<package scheme>/<engine>/sockets=<value>`.
A claim must be persisted before mutation. The Firewall status refresh and a
launch that encounters pending-write recovery leave saved preferences alone. Repeated loads and relaunches do not retry the
same target; storage is bounded at 32 claims without eviction. Explicitly restart
Firewall while jailbroken (OFF then ON) to retry an existing claim. Claim write or
capacity errors prevent the operation. Release wording does not clear these claims.

The restart transaction retains an independent old snapshot, preflights and copies
the candidate, saves/reloads the old filter OFF if enabled, waits for provider
isolation, stages/saves/reloads the candidate OFF, validates fields and the actual
policy, then enables/saves/reloads/validates it and waits for its own activation's
control heartbeat. Normal candidates keep browser scope YES and the saved socket
scope. Existing organization/other configuration fields and complete vendor entries
are copied; schema/engine/activation metadata are refreshed. Restoration preserves
previous scope and description while applying the required policy and a fresh
activation. Saved rules are not rewritten.

| Reported state | Meaning and action |
| --- | --- |
| No installed configuration | A successful preference load can report an absent filter. The fallback policy is applied when you enable Firewall. |
| Unchanged / not migrated | Capability or candidate preflight failed before preference mutation. An old enabled filter may still lack fallback. Disable/remove controls remain available. |
| Restored | The previous scope/description was restored through the same required-policy checks and a current control heartbeat. A saved socket preference may still be pending; the app retains the mismatch message. |
| Verified OFF | Preferences were reloaded and read OFF. Rules remain; NetShield2 protection is off. This is not a measurement of connectivity. |
| Saved preferences unavailable | The latest preference load failed. The dashboard can show the last successful result while changes stay paused. Tap the Firewall status row to refresh. |
| Saved On or Off with changes paused | Preferences loaded successfully, but an outstanding write or a local record blocks changes. Follow the recovery message below. |

Ordinary preference loads and writes have 10-second phase deadlines. Both saves
during first installation, staging and activation, allow up to 60 seconds each
for system authorization. Provider isolation and current-control waits each have
a 15-second bound. Restart transactions have a 180-second coordinator deadline.
Disable and reset have a 120-second coordinator deadline, and the uninstall
helper has an independent 30-second watchdog. If consent is cancelled or a write times
out, refresh to read what was saved. A timeout can leave a submitted write in
progress. The app and helper block another preference mutation until they can
reconcile it.

Tap the **Firewall status** row while jailbroken to refresh preferences and policy.
Each new save has a unique receipt recorded before submission. The app can verify
that exact receipt with a fresh preference load after returning from Settings or
when iOS signals a preference change. If neither signal nor the save callback
arrives, the phase deadline allows one final read with a 10-second budget.
A verified active phase can continue through its usual validation. If the
transaction has already ended, refresh clears the fence when it finds the
receipt, and the user can explicitly enable or remove the filter.

An acknowledged write awaiting local cleanup can recover after shared storage
access is restored. If upgrading from 2.6.7 and an earlier save still blocks
changes, fully reboot, return to the jailbreak and refresh. Older records
lack a save receipt. A valid recorded boot ID can be reconciled on the next
verified kernel boot. For a readable legacy record with a missing or malformed
boot ID, first refresh and confirm that the dashboard says it recorded the
current boot. Reboot and refresh again so the app can match the same record
against the new kernel boot. A respring or userspace restart cannot supply
that evidence.

The 2.6.4 uninstaller predates the preference-write record. It can remove the
filter and policy while leaving a record from a newer install in the shared
container. After reinstalling, a saved Off state alone cannot settle that
record. For a recognized pending removal, a successful read showing the filter
absent allows initialization of missing rules while changes to preferences stay
paused. If the record may be for a save, policy initialization waits for recovery.

If the first installation fails after an acknowledged write, the restart
transaction reloads preferences and removes a profile it can still identify as
its own. It verifies absence before reporting recovery. A write without
acknowledgement or matching receipt evidence keeps the fence in place. When investigating an Invalid entry, capture the
`NetShield2 preference`, `NetShield2 control startup` and `NetShield2 data startup`
log lines. The stage and error domain/code distinguish a preference failure
from a provider startup failure.

If the kernel boot identity or shared storage is unavailable, follow the specific
dashboard diagnostic. The filter remains accessible in **Settings > General >
VPN & Device Management > Content Filter**. A successful preference load shows
the saved state while the app continues to protect any unproven write. Disable
and removal can proceed once the coordinator verifies mutation readiness, even
when policy or the private fallback property cannot be read.

Diagnostics retain `NetShield2 boot-policy loaded` before migration and stages for
candidate copy, old OFF reload, staged OFF reload, enabled reload, current heartbeat,
restoration and verified-OFF recovery. They include OS, package scheme, capability,
actual value, scope/metadata and `channel: stable`. A copied candidate is not persisted
state; only reload stages follow preference loads. No new log collection is required.

## Uninstalling before an older version or jailbreak switch

The fallback property belongs to NetShield2's saved filter configuration; it
is not a separate global switch or daemon. Package removal runs the installed
app's `--remove-filter` command as the mobile account. It loads NetShield2's own
manager, removes the entire configuration and reloads preferences to require both
an absent provider configuration and Firewall disabled. Removal does not require
reading or resetting the private property; there is no private-method capability
gate on removal. No unrelated profiles are removed.

After verified filter removal, cleanup waits for provider, policy, activity and export locks and
removes `policy.plist`, `monitor.plist`, `notification-retry.plist` and
`activity-clear.plist`, plus only the export cache at
`Library/Caches/NetShield2/Exports`. Reset Settings also clears this cache. Cleanup
keeps the rest of the app-group container. The coordinator clears reconciled recovery
records while holding configuration ownership. The helper removes the app's complete preference
domain, including `NSBootPolicyAutomaticAttempts`, and requests removal of pending/delivered
notifications. Small lock files are intentionally retained to preserve lock
coordination; they do not contain the fallback policy. Cleanup errors or the
30-second command timeout cancel package removal. If preferences are verified absent
but local cleanup fails, address the reported storage stage and retry removal.
Icon-cache invalidation and the
scheduled respring follow successful cleanup; icon-cache rebuilding alone does not
establish that NetworkExtension preferences were removed. Record the helper exit and
`dpkg-query` status before and after removal. Check any remaining icon separately.

A successful full uninstall is the relevant cleanup before installing an older
version. Turning Firewall OFF or using Reset Settings retains the installed filter
configuration, and an in-place upgrade/downgrade preserves it too. Once the installed
configuration and app are removed, the older app creates its own configuration on
enable; the removed app has no process left to reapply its policy. Switching from
RootHide to rootless at the same time also changes the environment, so the outcome
will reflect both changes and cannot isolate the private property by itself.

Source review found no additional fallback-specific removal operation needed. Existing
native removal tests cover preference failures and retained configuration/enabled
state. Focused added cases cover removal of a true saved fallback policy while
enabled/disabled and with unavailable/throwing private methods, plus clearing and
reclaiming migration targets after preference reset. These injected tests do not
inspect the user's live device or another jailbreak installation.

## Packages, draft and downloads

The workflow prepares exactly these metadata-driven package names for current
`control` metadata:

| Variant | Debian architecture | Package / artifact |
| --- | --- | --- |
| RootHide | `iphoneos-arm64e` | `com.eolnmsuk.netshield_2.6.8_roothide.deb` / `NetShield2-2.6.8-iOS15-18-roothide` |
| Rootless | `iphoneos-arm64` | `com.eolnmsuk.netshield_2.6.8_rootless.deb` / `NetShield2-2.6.8-iOS15-18-rootless` |
| Rootful | `iphoneos-arm` | `com.eolnmsuk.netshield_2.6.8_rootful.deb` / `NetShield2-2.6.8-iOS15-18-rootful` |

Pinned Theos inputs, source metadata/entitlements, formatting, native tests, packaging
and signing fixtures, shell syntax, actual `.deb` extraction, staged validation and
actual executable signing/entitlement checks remain in CI. Rootless extraction uses
`var/jb/Applications/NetShield2.app`; the other variants use
`Applications/NetShield2.app`. Packaging fixtures run all three uninstall variants
on POSIX, so CI does not separately repeat the selected uninstall fixture.

PR/manual runs build only. After all three builds pass, a push to `main` can
prepare a draft for the current version. It requires matching source revisions,
package sizes and SHA-256 hashes for the three debs, plus recorded tool versions.
Manifests stay in Actions artifacts. The workflow uploads and verifies temporary
revision-specific debs, promotes them, removes every extra attachment from that
version's draft and verifies the entire asset list. A completed draft contains
exactly the three named debs. GitHub's generated source archive links are separate
from these attachments. Failed preparation leaves the draft labeled incomplete.
Stale builds stop, published releases stay untouched, and publication is manual.

A draft is not a public download. The in-app updater checks published stable
releases on the selected schedule, with a separate manual Check Now action.
It never downloads or installs a package. Ordinary uninstall removes rules and
history, so export anything needed before following uninstall instructions.

## SDK naming and validation scope

Keep target `iphone:clang:16.5:15.0` and directory `iPhoneOS16.5.sdk`. The bundled
archive/extracted SDK internally report **16.4**, CanonicalName `iphoneos16.4`,
ProductVersion **16.4**, ProductBuildVersion **20E238**. The pinned archive SHA-256 is
`5e0fd3f01266cce4ce012d4a99b38eb56578fca40d09edc81cd83dee958202fb`.
The filename is not independent proof of internal Apple 16.5 metadata. No SDK or
Theos substitution is part of this stable release preparation.

The historical device reports above apply only to the stated 2.6.2 packages and
setups. The [hardening plan](../plan.md) and [implementation record](hardening-implementation.md)
describe the current source, executed checks, and remaining evidence. Synthetic
layout and Mach-O fixtures do not establish that a real deb builds, signs or runs.
Local libclang checks parse Objective-C without linking or executing it.

For a candidate release, run native regressions and supported sanitizers on macOS,
then validate the three actual extracted packages. The workflow checks Mach-O
platform and deployment commands, dependencies, CodeDirectory identifiers and
embedded hashes. It requires each CodeDirectory to cover XML entitlements and
any DER entitlement blob. The workflow compares the XML extracted by `ldid -e`
with the source entitlements. These checks cover the content of the jailbreak
packages. Verify iOS jailbreak acceptance and enforcement separately. Record
source/package hashes and the exact OS, device, jailbreak and scheme for every
device result.

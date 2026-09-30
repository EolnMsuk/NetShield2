# Reliability fixes: 2.2.4 / 20025

The implementation preserves the 2.2.3 Local Port / Remote Port entry flow,
Allow/Block/Cancel colors, and local-before-remote activity display.

## Stage 1: preferences and verdict correctness

- Enable and rules-only reset preserve Apple allowance and socket preferences.
- IPv4-mapped IPv6 addresses use the IPv4 rule key. Conflicting equivalent
  persisted IP rules merge conservatively; a block wins over an allow.
- Scoped IPv6 endpoints match unscoped IP rules on every interface.
- Socket flows with potentially relevant missing endpoint fields defer their
  verdict until a data callback. If required metadata is still absent, they
  block. No payload is persisted or inspected for content.

## Stage 2: lifecycle, DNS, and permission recovery

- Restart validates policy, disables, waits for the provider lifetime lock,
  reloads preferences, and enables a uniquely tagged configuration. The new
  control provider must report that activation before success is reported.
- Stop/start polling is bounded to 15 seconds per phase. Failure attempts one
  rollback to the prior configuration if the firewall was originally enabled.
  Preference calls remain serialized; an outstanding save is never raced by a
  second save. Framework preference completion itself cannot be cancelled.
- DNS uses at most four concurrent domain lookups (eight DNSService references),
  each cancelled after three seconds. Results publish independently, replace
  previous answers, and expire at the earliest returned TTL, capped at five
  minutes. Old cache entries without expiry and historical observed IPs are no
  longer used. DNS address fallback remains approximate on shared hosting and
  is described in the UI.
- Failed DNS publication retains bounded pending results and retries separately
  from resolution. Diagnostics appear in the dashboard. Only successfully
  saved monitor requests can submit permission banners.
- Explicit Use Default Rule records a per-identity ask generation. Old history,
  in-flight requests, and stale answers cannot suppress a fresh prompt.
- Notification startup enumerates stale banners. Late submit/settings callbacks
  cannot reinstate revoked attempts. Provider history remains session-local;
  unanswered requests must be retried after a provider restart.

## Stage 3: activity correctness

Activity coalesces reports by process and flow ID before grouping. Cumulative
byte totals use the maximum for each flow, not the sum of repeated reports.
When IP information is absent, the normalized domain distinguishes peers.
Events without flow IDs remain separate because reliable deduplication is
impossible. Local and remote ports both remain in the grouping key.

## Automated validation

Validation performed on the Windows development host on 2026-09-30:

- Release metadata/source/entitlement/script validation: passed.
- clang-format 19.1.7 verification: passed.
- All production and regression Objective-C translation units parsed against
  the bundled iOS 16.5 SDK, targeting arm64 iOS 15, with warnings as errors: passed.
- Executable native regression suite: attempted, but unavailable on Windows.
- Package linking/signing and device behavior: not verified here. No updated deb
  was produced by these source edits.

On macOS with Xcode command-line tools:

```sh
python3 scripts/test.py
python3 scripts/test_uninstall.py
python3 scripts/validate.py
python3 scripts/check_format.py
```

`RecoveryTests.m` covers mapped addresses, missing local/remote metadata,
DNS expiry/replacement and lock contention, bounded resolver concurrency and
cancellation, stale generations, publication failure/recovery, orphan banners,
restart rollback/late callbacks, and distinct-flow activity aggregation.
The existing suite now expects rules-only reset to preserve preferences.

## Device checks required before release

Use supported jailbroken iOS versions and test both browser and socket traffic.

1. Upgrade from 2.2.3 while enabled. Verify the new activation/build appears and
   no two control providers hold the lifetime lock. Repeat with delayed shutdown,
   socket preference changes, and a failed replacement configuration save.
2. For both Apple-allowance and socket-filter settings, test all combinations
   through off/on, relaunch, rules-only reset, and full reset. Verify the port
   entry flow, button colors, and local-before-remote display remain unchanged.
3. Exercise TCP and UDP, both directions, including flows initially lacking
   endpoints. Verify no final allowance precedes a potentially matching local
   port, remote port, or IP rule. Verify the data-callback need-rules path and
   its permission completion behavior on each supported OS.
4. Test mapped IPv4 and scoped IPv6 endpoints, DNS rotation, NXDOMAIN, unreachable
   DNS, shared IPs, and rule changes during DNS lookup. Confirm obsolete addresses
   expire and domain rules with known hostnames continue to work without DNS.
5. Simulate monitor-write failure and policy-lock contention. Requests must
   continue timing out, unusable banners must withdraw, and recovered requests
   must be published before banners return. Test an old callback after recovery.
6. Expire a request, select Use Default Rule, and reconnect. Repeat with a rapid
   allow/default change before the provider refresh, unrelated policy changes,
   and an action from a stale notification.
7. Terminate the control provider without its stop callback; restart it and
   verify orphan banners disappear while new requests still work.
8. Check one flow with permission/admission/closure reports counts once, repeated
   cumulative totals do not inflate bytes, and different hostname-only peers do
   not collapse into one activity row.

The Windows SDK syntax checker does not execute Objective-C tests, link binaries,
or validate NetworkExtension behavior. A control-provider heartbeat is also not
proof that every OS traffic path is filtered. Build and test the new package on
macOS/device before distributing it; the old 2.2.3 deb does not contain these fixes.

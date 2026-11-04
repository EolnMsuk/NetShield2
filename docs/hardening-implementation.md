# Hardening implementation record

Local source candidate, November 3, 2026. Package version 2.6.5,
engine 20043, policy schema 3 and monitor schema 2. No releases were published,
no changes were pushed, and no live filter or device settings were changed.

| Finding | Source change and regression coverage | Remaining evidence / limits |
| --- | --- | --- |
| H01 | One current submission record per token, distinct banner IDs, monotonic deadlines and retry/retirement fencing. Added delayed, duplicate, missing, retry-revision, re-add and direction-change fixtures. | Execute native notification fixtures and check delivery on iOS. |
| H02 | Main-queue coordinator, cancellable phase timers, overall deadline, shared app/helper lock and durable pending-write marker. Fresh fingerprint check before recovery writes; reloads verify saved preferences. Fixtures cover late/missing/duplicate/background callbacks, held write lock and external replacement. | Run native tests and Settings/helper races on device. An orphaned marker is reconciled only after a recognized new kernel boot; verify boot identity access. If identity is unavailable, the marker is left in place and Settings remains the explicit recovery path. |
| H03 | Disable/absence readback before cleanup and after contention. Lock order is configuration → provider → policy → activity → exports. Keep lock files stable and return partial cleanup details. Active shares prevent cleanup; retries can resume after close. | Run separate-process contention, kill-between-files and actual uninstall/reinstall fixtures. External Settings does not take the app lock. |
| H04 | Serial control state, bounded work and reply admission, detached exactly-once verdicts, captured metadata, session checks and no late completion-side writes. Added a reentrant reply/admission fixture. | Exercise the actual NE providers, queue pressure and stop/report races. Bounded storage operations still run on the control state queue; measure before adding another publication pipeline. |
| H05 | Explicit startup/stop states, allocation checks, teardown acknowledgement from the DNS queue, shutdown fencing, and bounded final telemetry retry. | Run provider fault injection, resource/descriptor soak and lock contention on device. Initial monitor-publication failure still returns a startup error; changing that behavior needs device evidence. |
| H06 | Separate A/AAAA batches, quiet settling window, bounded incomplete timeout, interface-aware TTL/removal, reserved lookup slots, backoff and rule/path generation fences. Answer validity uses wall and monotonic expiry and a boot identity when available. Fixtures include synchronous/nil factories at 1/64/256/4096 rules. | Measure coverage age and backlog; no measured resolved-domain capacity is claimed. Verify real DNS-SD behavior, path notifications, boot identity availability and persisted cache invalidation timing. |
| H07 | Bounded descriptor reads, no-follow/nonblocking opens, verified modes/identity, known leaves, atomic publication and file sync for user writes/clear boundaries. Added FIFO, symlink, directory, rename and growth faults. | Verify iOS app-group modes, pre-unlock access, disk/full-descriptor faults and power-loss durability. Current protection classes are preserved; atomic rename plus file sync is not a power-loss guarantee, and DNS cache rewrites are not flushed. |
| H08 | Typed monitor read failures, strict Boolean/counter/string limits, duplicate token rejection, recognized policy fields, supported legacy defaults, and session/activation/ask-generation checks at decision time. Added malformed telemetry/future schema fixtures. | Run native malformed-input corpus/fuzzing and migration fixtures. Freshness metadata is not authentication against an app-group writer. |
| H09 | Documented schema-3 precedence and corrected editor wording. Added decision parity cases for legacy/custom overlap and unsupported directions; existing precedence tests are retained. | Run native differential tests and device flow/metadata coverage. No uniform block-priority migration. |
| H10 | Per-flow max counters, transport-aware groups, explicit mixed outcomes/host counts, saturating totals and generation-based activity clears for supporting providers. Legacy cutoffs remain readable. | Run native rollback/restart and grouped/raw export fixtures. Old publishers still use their wall-clock cutoff contract; verify upgrade/downgrade behavior. |
| H11 | Broke the manual-identity alert retain cycle, protected idempotent lock release, canceled transaction timers and added asynchronous respring child reaping. | Instruments/Leaks, static analyzer and failed child exit tests on supported platforms. Spawn success alone does not confirm a respring. |
| H12 | One data-flow evaluation result, checked direction indexing, canonical app rules, reverse DNS address lookup and a short identity-scoped negative parse cache. Descriptor reconciliation remains on the data path. | Measure latency, allocations and syscalls; broader indexes or cross-revision static compilation reuse need evidence. |
| H13 | Changed snapshots publish promptly; unchanged payloads use a three-second heartbeat, with one-second reconciliation. DNS updates batch with a bounded backlog and do not flush transient answers. | Measure idle writes/wakeups, publication latency, flood and full-buffer behavior. No energy savings are claimed. |
| H14 | One worker for dashboard snapshots, grouping, rule writes, clear, permission responses and export. Main delivery is generation checked. Added cell reuse, bounded height keys and stale permission-sheet dismissal. | UIKit/notification background, Dynamic Type, rotation/iPad, swipe/search and responsiveness checks. Some preference-transaction verification and cleanup I/O remains synchronous with the transaction. |
| H15 | Reject same-object copies, deep-freeze vendor metadata, guard public/private field extraction, verify copied fields, validate migration claims and fence newer engines. Added alias/deep-copy/malformed-claim fixtures. | Verify actual private-property readback, persistence, stock-boot fallback and downgrade on device. Migration claims are capped at 32; explicit restart can retry existing claims. Export before an intentional settings reset to clear the claim store. |
| H16 | Stream and cap GitHub responses, restrict redirects, cancel stale results, redact vendor logs and protect active export lifetime across app/helper. | Verify update and export paths on device. App privileges and data protection are unchanged: the app-group and NE entitlements support sharing/registration; no-sandbox is used by the respring launch path; the need for platform-application and get-task-allow still requires a per-jailbreak matrix. Provider isolation is retained. |
| H17 | Extracted bounded file access, monitor schema, export registry and policy reader; data target now links only reader/evaluator/storage primitives. Kept adapters and build/test source lists consistent. | Native link/package checks. No broad parser rewrite or new daemon. |
| H18 | Pinned action commits, recorded source and tool versions plus final hashes, added Mach-O/content checks and verified draft staging with mocked stale/partial failures. Deferred respring checks version/state and a supersession marker. | Run real POSIX lifecycle checks and three package builds/signature checks. Confirm overlapping dpkg behavior: PID reuse can postpone the worker to its deadline and unrelated package activity is not covered by the NetShield2 marker. Draft review and publication remain manual. |

## Baseline and verification scope

The initial workspace has no Git metadata. A workspace-local source snapshot is
used for diff review. The baseline passed metadata, formatting, three synthetic
package layouts, concurrent metadata publication and two signing-ID parser tests.
The original bundled syntax runner omitted `NS_JAILBREAK_TYPE`; the replacement
uses the Makefile definition and can check both snapshots with `--sources`.

Final Windows checks actually executed:

- `scripts/validate.py` and the clang-format 19.1.7 check passed.
- `scripts/check_objc.py` parsed 26 baseline and 36 final Objective-C translation
  units with ARC/blocks, arm64 iOS 15 and the rootless definition, without
  diagnostics. This did not link or execute Objective-C.
- Workspace-local packaging fixtures passed for all three layouts, including
  concurrent metadata publication and deterministic read-sharing failure. A
  full run exposed an intermittent Windows `PermissionError` in the old output
  equality shortcut; it now falls back to bounded atomic replacement.
- Two signing-identifier fixtures, five synthetic Mach-O/content tests and
  mocked draft preparation (stale source, corruption, partial upload/promotion
  retry, published release preservation) passed. Python scripts and workflow
  YAML parsed; workflow action references are full commit SHAs.
- Native regressions and isolated respring tests could not execute: macOS
  Foundation and the Xcode command-line tools are unavailable. POSIX `sh` is
  unavailable, so all postinst/prerm execution and shell syntax checks remain
  open. Real debs, signing verification, sanitizers, analyzer, device behavior
  and performance were not exercised.

The hardening diff before the version bump was generated under
`.validation-tmp/hardening.diff`. Scope review confirmed no unrelated binary,
package version, entitlement, registration, or plan changes. The candidate is
not signed off for production.

The reported macOS RootHide CI run for 2.6.5 stopped at the two-export staging
assertion. The fixture now prints the staging error on failure. The macOS
fixtures use temporary storage without setting backup metadata, and iOS still
requires backup exclusion before writing export data. Empty shared paths now
return the container URL directly. Reset and removal tests verify that an open
share prevents cleanup. The next RootHide run passed export staging and reached
the DNS factory fixture, where it timed out. The resolver now keeps ordered
pending work and counts due retries by binary search. The regression retains the
10-second limit at 4,096 rules and verifies one result per key. It also covers
retry ordering and rejects invalid answer lifetimes before calculating backoff.
Native CI confirmation for this change remains pending.

The reported rootless build reached package verification. Its embedded hashes
passed, then macOS `codesign` rejected the `ldid -S` signature. CI now verifies
the CodeDirectory identifiers, code pages and entitlement hashes directly on
each extracted executable. It still compares the XML entitlements extracted by
`ldid` with the source plists. The signing command and entitlements are preserved.
This checks package content and identity, with iOS acceptance tested separately.

## Release gates

- Run `python3 scripts/test.py`, `python3 scripts/test.py --sanitizers address,undefined`,
  and the supported separate thread-sanitizer build on macOS. Run the analyzer,
  POSIX lifecycle fixtures, and the actual rootless, RootHide and rootful package
  checks, including CodeDirectory identifiers, entitlement readback and hashes.
- Record representative supported iOS/jailbreak pairings, saved preferences,
  active enforcement, stock/forced boot, return to jailbreak, reset/removal,
  privacy, battery/latency, and an extended resource soak as specified in `plan.md`.
  Provider responsiveness does not establish enforcement. Active policy read
  failure still drops flows; startup errors may enter the separate unavailable
  provider fallback.
- Verify the final draft contains the reviewed source and package hashes. Inspect
  the three device packages and confirm the manual release decision separately.

## November 3, 2026 repair addendum

The [2.6.5 regression repair plan](../plan2.md) is implemented locally for
package 2.6.6 and engine/build 20044. Policy schema 3 and monitor schema 2 are
retained. This addendum records source changes and Windows checks. The sections
above record the earlier 2.6.5 work and evidence.

| Finding | Local repair |
| --- | --- |
| F1 | Documents and stable locks use known leaves and directory-relative operations under an identity-checked app-group root. Both spellings of the container can identify the same directory. Bounded reads, cache identity checks, leaf no-follow and private file creation remain in use. |
| F2 | The versioned marker records operation, phase, kind and boot availability before dispatch. OS callbacks match the record and persist acknowledgement before retirement. A timeout keeps write ownership until the callback. |
| F3 | Read-only dashboard loading also reconciles eligible markers. A recovery witness ties readable bootless or malformed records to a SHA-256 fingerprint and a verified kernel boot. The dashboard displays saved preferences, policy, recovery and provider health separately. |
| F4 | Reset and helper admission share the coordinator and verify saved state before cleanup. Retries distinguish lock contention from permanent storage failures. Cleanup diagnostics identify the remaining stage and preserve the original error. |
| F5 | A dashboard refresh can retry bootstrap on the serialized storage worker while it owns the configuration lock. Defaults are created only after the policy leaf is confirmed absent in the verified root. |
| F6 | The completed draft asset list is verified in full against the three debs. Legacy provenance and other extras are removed from the guarded current-version draft. Manifests and toolchain records stay in CI artifacts. |

Windows validation covered source/metadata consistency, clang-format 19.1.7,
syntax parsing of all 36 Objective-C translation units for arm64 iOS 15 with
the rootless definition, and mocked draft preparation including stale builds,
published releases, corruption, legacy extras and upload/promotion/cleanup
retries. The focused native fixtures cover aliased container paths, durable
acknowledgement, legacy recovery, and verified cleanup of an already absent
filter. Native tests, POSIX maintainer-script execution, signed packages and
on-device outcomes remain to be verified. See the
[behavior and evidence guide](stock-boot-testing.md) for recovery and device checks.


## November 3, 2026 follow-up for 2.6.7

Device feedback reported an Invalid filter entry after enabling 2.6.6, followed
by paused changes and missing policy after removal and uninstall with 2.6.4.
The 2.6.4 reference confirms that its cleanup predates the pending record and
can leave it in place after removing the policy. The report establishes the
dashboard recovery state. The cause of iOS Settings' Invalid label still needs
on-device evidence.

- First installation allows authorization on either save and verifies removal of
  its own failed profile when no write remains unresolved. The disabled-stage
  and enabled-stage fallback checks still gate activation.
- Reset, uninstall and failed-first-install recovery share removal readback.
  A completed remove with an error requires a successful fresh absence check
  before cleanup can proceed.
- Dashboard bootstrap can initialize missing policy with a known removal record
  and a freshly verified absent filter. A record that may represent a save
  continues to block initialization until recovery.
- The policy reader retries a concurrent replacement once. Control startup
  retries transient initial publication failures before reporting startup
  failure. Stage and error-code diagnostics cover both providers and preference
  submissions and callbacks.

Windows source and metadata validation, formatting and syntax parsing passed.
Focused native fixtures were added for both authorization phases, failed first
installation cleanup, remove-error readback, saved records after downgrade and
policy replacement detection. Native execution and device acceptance are pending.

## November 3, 2026 follow-up for 2.6.8

The 2.6.7 reports on RootHide and rootless persisted after system authorization.
The supplied screenshots show saved Off, readable rules, fallback readback and
the same pending-save fence before and after a removal attempt. That state
explains the blocked actions. The screenshots do not include a provider error
code or identify whether the pending save was staging or activation.

2.6.8 records a unique vendor receipt for each submitted save. A successful
fresh preference load can settle the exact record while holding configuration
ownership. Staging and activation have different receipts. A stale or missing
receipt leaves the fence in place. An active enable still validates the
disabled stage, enabled settings and private fallback. Late proof only
releases the fence. Older records without receipts still use the documented
kernel boot recovery.

Focused fixtures cover committed saves without callbacks during both
first-install phases, receipt recovery after relaunch, duplicate callbacks and
unproven writes. Windows formatting, metadata and Objective-C syntax checks
passed. Native test execution and validation on the affected devices are pending.

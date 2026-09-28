# Development

## Project layout

- `App/main.m` launches the app; `NSAppDelegate` owns the window and notification responses.
- `NSDashboard.m` handles dashboard lifecycle and policy editing. Its Configuration, Notifications, and Table categories keep the asynchronous configuration flow, permission UI, and table presentation in separate files. The internal header is shared only by those implementations.
- `FilterData` evaluates new flows from an immutable policy snapshot.
- `FilterControl` owns the provider session, permission queue, reporting, and monitor publication. `NSPermissionNotifications` owns submission and retry state for one provider run.
- `Shared` contains policy validation, bounded permission queues, storage, policy caching, and file locks.
- `Tests/RegressionTests.m` exercises production shared code and notification handling with a controllable notification center. It does not use real notification authorization or install a filter.

## Storage and concurrency

All production policy writes go through `NSEnsurePolicy`, `NSUpdatePolicy`, or `NSResetSharedState`. Apply edits to the document supplied by `NSUpdatePolicy`; never save a dashboard snapshot. Its nonblocking `policy.lock` covers reading, applying the mutation, validating, and atomic replacement. Contention returns an error rather than blocking the main thread indefinitely.

The control provider holds `provider.lock` from startup through its final stopped snapshot. Reset first removes the system configuration, then acquires this same lock before changing shared state. Process exit releases the lock automatically. The lock files must never be removed or atomically replaced: doing so would let two processes lock different inodes. Reset preserves them.

Reset takes the provider lock before the policy lock. No operation takes these locks in the reverse order. Old providers did not participate in this protocol; a known legacy configuration requires an explicit stopped monitor before reset. If shutdown cannot be established, retry after starting and stopping the updated provider.

Each provider instance serializes its mutable state with `@synchronized(self)`. Its notification dispatcher has its own synchronization and never calls back into the provider. Stop invalidates that dispatcher; late callbacks can only clean up the old notification identifiers. Timers and delayed refreshes check the captured provider session.

The policy cache opens the file and checks inode, size, and nanosecond modification/change timestamps on every read. Unchanged files reuse the validated immutable object; replacement, removal, access failure, or invalid content cannot fall back to the previous object. A changed file is read through the opened descriptor with a size bound and a before/after metadata check. `handleRulesChanged` also invalidates the cache. The data provider never takes a writable lock or writes shared files.

The queue holds at most 64 active app requests and 256 connection waiters, with 16 waiters per app. Timeout completes waiters once and moves their request into a separate 64-entry history. Oldest history entries are evicted first. An expired request can still be answered while it remains listed; retrying it does not reopen its original connection. A new connection from an evicted identity can create a new prompt. Overflow and eviction totals reset when the provider restarts.

## Checks

On macOS with Xcode command-line tools:

```sh
python3 scripts/validate.py
python3 scripts/test.py
python3 scripts/check_format.py
```

Use clang-format 19.1.7. Include the hidden `.clang-format` file at the repository root when copying or uploading the project. The check requires this exact configuration and does not fall back to LLVM defaults. Apply formatting to the `.m` and `.h` files under App, Shared, FilterData, FilterControl, and Tests. Formatting and native regression checks also run in the macOS build workflow before packaging.

The native suite covers policy mutation preservation and concurrent writers; cache reuse, replacement, corruption, removal, and oversize files; queue capacity, history eviction, directions, exact deadlines, and cancellation; stale/missing monitor reset while the lifetime lock is held; and notification completions after removal, stop, or dispatcher release.

`Shared/NSConstants.h` defines the engine/build number and shared limits. Update all three bundle versions when changing the engine; `scripts/validate.py` checks them against that constant. The release version is 2.0.1 and the engine/build remains 20014. The validator also checks that all three bundle release versions match the package version. The existing root-level `.deb` contains version 2.0.0 / build 20014; rebuild it to produce version 2.0.1.

## Device verification before release

1. Build the rootless package through CI and install it on each claimed iOS/jailbreak combination. Verify the app group, both providers, and notification actions while the app is foregrounded, backgrounded, and the device is locked.
2. Answer a banner while scrolling the dashboard, then edit another rule. Confirm both decisions remain saved.
3. Generate more than 64 distinct unanswered identities in batches spanning the timeout. Confirm new prompts continue, history stays bounded, and overflow/eviction counts are visible.
4. Reset while connections and notification submissions are pending. Confirm it waits for shutdown, preserves rules if locking fails, and never resurrects history. Repeat after an abrupt provider termination and when upgrading from build 20013.
5. Corrupt or remove the policy while filtering, then restore valid content. Confirm new flows block during failure, the dashboard reports the error, and both recover after restoration.
6. Exercise a connection burst with a large rule set. Measure CPU, latency, and monitor-write frequency; no throughput improvement has been claimed from static checks alone.
7. Verify directional rules and existing admitted-flow behavior. Test Prepare for uninstall and network access after removal.

The Windows editing session validated metadata, formatting, Python syntax, and all Objective-C translation units with Clang 18 against the checksum-pinned iOS 16.5 SDK targeting iOS 15. It could not link an iOS package or execute the native macOS suite. CI and device results must be recorded separately; semantic checks are not runtime tests.

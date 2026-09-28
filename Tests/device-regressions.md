# Device checks for system allowance and support links

Build and install the updated sources using the existing Theos workflow. The deb
already in the project root predates these changes. These checks require iOS;
cross-compilation does not verify banner delivery.

1. Enable Firewall, set Default Rule to Ask me, and enable NetShield2 notification
   banners. Disable Focus for this check. Enable Allow all iOS system processes.
   Generate new connections from identities beginning with `com.apple.`,
   `.com.apple.` and `Apple.com.apple.` (including `Apple.com.apple.Preferences`). Each should be allowed with no permission
   request, including identities with saved block rules. Disable the switch:
   saved rules should apply again, and identities without rules should ask again.
2. Set GitHub and Venmo to Use Default Rule. Tap each support link from
   NetShield2. It must open directly, without the old Firewall warning. Verify
   the destination's permission banner appears after NetShield2 backgrounds.
   Long-press Allow app without returning to NetShield2 and verify the page
   loads (retry the page if its original request has already timed out).
   With Firewall off, links should open directly without a permission request.
3. Repeat with a destination app absent so the link opens the default browser;
   set that browser to Use Default Rule first. Verify the same background banner
   and Allow app action work for the browser.
4. Repeat a link handoff and leave the request unanswered for over 30 seconds.
   Reopen the destination app: traffic should remain blocked, without repeated
   banners. Allow from Notification Center, then retry the connection. Also
   verify Keep blocking saves a block rule.
5. While NetShield2 stays open, trigger an undecided app's connection. The request
   should appear in the inbox without a foreground banner or notification sound.
   Repeat with Settings and system allowance enabled: there should be neither
   an inbox prompt nor a banner for `Apple.com.apple.Preferences`.
6. Open Support Developer. The menu row must read exactly `Bitcoin`. Tap it,
   verify the existing copied-address confirmation, and paste into a text field
   to confirm `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL` was copied.
7. Upgrade from build 20012 or 20013 with Firewall enabled, then open NetShield2. Verify
   the filter restarts once with engine 20014 and preserves rules and the system
   allowance setting. Reopening NetShield2 must not restart it again. Repeat the
   Settings check above to ensure the current provider uses the updated matcher.
8. Quickly return to NetShield2 during a link handoff. Foreground banners must
   remain suppressed; the inbox must still work. Wait over 30 seconds and leave
   normally: the old handoff must not replay anything. Also cancel a destination
   launch where iOS offers cancellation; no handoff notification should appear
   while NetShield2 stays open.
9. Leave an unrelated request pending before tapping a support link. The handoff
   must not replay that unrelated notification. Repeat with an already allowed
   destination: the link must open without a permission prompt. Background
   requests outside support-link launches must retain their existing behavior.

The handoff records only request tokens received by the foreground notification
delegate after a support link is tapped. It becomes eligible only on the real
background callback, expires after 30 seconds, and is cancelled on return or a
failed URL launch. The provider rechecks its queue and policy, waits for any
original submission to finish, and consumes each token once per handoff. The
existing bounded submission-failure retries still apply. No process exit,
guessed app identity, saved-rule change, or firewall bypass is involved.

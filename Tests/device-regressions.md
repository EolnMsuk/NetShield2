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
   NetShield2. Verify the Firewall notice appears before leaving NetShield2,
   including after the Venmo chooser closes. Cancel must stay in NetShield2;
   Open link must open the destination. If the app is blocked without a banner,
   return to NetShield2, allow it in Waiting for your decision, and reopen the
   link. Verify the page loads. With Firewall off, links should open directly.
3. Repeat with a destination app absent so the link opens the default browser;
   set that browser to Use Default Rule first. Verify the same warning and
   return-to-NetShield2 flow works for the browser.
4. Repeat a link handoff and leave the request unanswered for over 30 seconds.
   Reopen the destination app: traffic should remain blocked. Return to
   NetShield2 and allow the pending request, then retry the connection. Also
   verify Block app saves a block rule.
5. While NetShield2 stays open, trigger an undecided app's connection. The request
   should appear in the inbox without a foreground banner or notification sound.
   Repeat with Settings and system allowance enabled: there should be neither
   an inbox prompt nor a banner for `Apple.com.apple.Preferences`.
6. Open Support Developer. The menu row must read exactly `Bitcoin`. Tap it,
   verify the existing copied-address confirmation, and paste into a text field
   to confirm `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL` was copied.
7. Upgrade from build 20012 with Firewall enabled, then open NetShield2. Verify
   the filter restarts once with engine 20013 and preserves rules and the system
   allowance setting. Reopening NetShield2 must not restart it again. Repeat the
   Settings check above to ensure the current provider uses the updated matcher.

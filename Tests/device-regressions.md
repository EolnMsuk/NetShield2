# Device checks for system allowance and support links

Build and install the updated sources using the existing Theos workflow. The deb
already in the project root predates these changes. These checks require iOS;
cross-compilation does not verify banner delivery.

1. Enable Firewall, set Default Rule to Ask me, and enable NetShield2 notification
   banners. Disable Focus for this check. Enable Allow all iOS system processes.
   Generate new connections from identities beginning with `com.apple.`,
   `.com.apple.` and `Apple.com.apple.`. Each should be allowed with no permission
   request, including identities with saved block rules. Disable the switch:
   saved rules should apply again, and identities without rules should ask again.
2. Set GitHub and Venmo to Use Default Rule. Open each support link from
   NetShield2. Verify the permission banner appears during/after the handoff.
   Long-press it and choose Allow app without returning to NetShield2. The app
   should connect; retry the page if its initial request already timed out.
3. Repeat with a destination app absent so the link opens the default browser;
   set that browser to Use Default Rule first. It should also show the banner.
4. Repeat a link handoff and leave the request unanswered for over 30 seconds.
   Reopen the destination app: traffic should remain blocked. The notification
   should remain available in Notification Center for a later decision. Allow,
   then retry the connection. Also verify Keep blocking saves a block rule.
5. While NetShield2 stays open, trigger an undecided app's connection. The request
   should appear in the inbox and as an actionable notification. Foreground
   notifications now intentionally use banners, sound and Notification Center
   so delivery is not lost during app transitions.
6. Open Support Developer. The menu row must read exactly `Bitcoin`. Tap it,
   verify the existing copied-address confirmation, and paste into a text field
   to confirm `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL` was copied.

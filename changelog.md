# 2.3.5

- Added a single **Add a Global Rule** editor at the top of Global Rules, with an app selector, comma-separated domains/IP ranges, remote/local ports, UDP & TCP / UDP / TCP, and an action.
- Combined rules match all selected conditions and remain in Global Rules, including rules scoped to a specific app. Existing global rules can be edited in the same form.
- Moved **Export Rules and Recent Activity**, **Reset Rules & History**, and **Reset Settings & Filter** into Advanced Settings, in that order.
- Updated the app, providers, and package to 2.3.5 (engine/build 20030).

# 2.3.4

- Reordered Support options and renamed reset to **Reset Settings & Filter**. Removed uninstall wording.
- Limited global rule previews to 5 entries followed by `...`.
- Moved **Edit Rule** below **Remove Rule**. Global edits now prompt for a rule before saving.
- Renamed **Allow In & Out** to **Allow**.
- Replaced **Use Default Rule** with a red **Remove Rule** action.
- Fixed swipe removal, including default app rules. Removed apps stay hidden across refreshes and relaunches unless a new rule is saved.

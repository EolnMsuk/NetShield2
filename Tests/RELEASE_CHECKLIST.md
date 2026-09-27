# NetShield 2.0.0 final device check

The owner confirmed that permission notifications and background decisions work when Do Not Disturb permits NetShield. This checklist checks the release UI and upgrade; it does not require resetting working rules.

1. Turn off the installed filter, close NetShield, install 2.0.0 and reopen. Confirm your existing rules remain and the custom Home Screen icon is intact.
2. Turn on Firewall. Confirm Active appears after startup; no separate Start prompts or Enable controls remain.
3. Set New apps to Ask me. For one test app choose Use new-app setting, close/reopen it and request fresh content. Long-press its notification, Allow, and verify the rule is saved without opening NetShield. Retry if the request timed out.
4. Repeat with Keep blocking. Verify fresh requests are blocked and there is no repeat prompt for a saved rule.
5. Turn Firewall off/on. Confirm off allows fresh connections and on restores your saved rules. The chosen New apps setting must not change.
6. Confirm Do Not Disturb with a NetShield exception permits banners. Without the exception, unanswered flows should remain blocked; the waiting list still works.
7. Use Advanced & support > Copy notification diagnostics. Confirm it copies current permission counts and provider status, without the removed test-notification fields.
8. Optional destructive check: Reset NetShield should clear rules/history, restore Ask me and leave Firewall off. Turn it back on to use it again.
9. Before removal, Prepare for uninstall should remove the system filter and show a success message. Then uninstall in Sileo.

Report any failed step and the copied diagnostics. The Mail/Sileo first-install icon may remain generic until the package's local icon exists; a hosted repository icon is needed to avoid that dependency.

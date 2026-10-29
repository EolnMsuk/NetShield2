# NetShield2 2.5.1 implementation plan

## Scope and confirmed decisions

This document plans the requested changes; creating it does not implement them. Preparation is limited to repository inspection and checking this document. No builds, test runs, or new tests are needed while generating the plan.

- Always derive the `.deb` filename version from the current `Version` field in `control` at build time. The format is `com.eolnmsuk.netshield_<control Version>_<rootful|rootless|roothide>.deb`; never hardcode the filename version. For the planned **2.5.1** release, this produces:
  - `com.eolnmsuk.netshield_2.5.1_rootful.deb`
  - `com.eolnmsuk.netshield_2.5.1_rootless.deb`
  - `com.eolnmsuk.netshield_2.5.1_roothide.deb`
- Apply the section-title and Clear-button styling to the conditional **SYSTEM RULES** section too. There are three normally visible Clear buttons and a fourth when System Rules is shown.
- Use a common **17 pt base font with Dynamic Type scaling** for dashboard section titles.
- Tapping the search field's x clears the query and preserves the keyboard's previous visibility: hidden stays hidden; visible stays visible.
- Provide an always-available native keyboard accessory with a Done button to dismiss the keyboard, including when the query is empty.

## Relevant existing structure

- `control` currently declares version `2.5.0`. `scripts/sync_version.py` copies the release version to the app and both provider plists and exports `PACKAGE_ID` and `PACKAGE_VERSION` for CI. Bundle build numbers follow `NSEngineVersion` separately.
- `.github/workflows/build.yml` already builds rootful, rootless, and roothide. Its package-existence check, extraction command, and artifact-upload path currently expect architecture suffixes instead of variant names.
- `App/NSDashboard+Table.m` owns section headers, the Recent Activity search field, its filtering callbacks, and table refreshes. Some section headers use UIKit defaults, while others use custom views.
- The custom headers currently use Footnote-sized titles, 20 pt horizontal margins, and Clear buttons with a minimum height of 44 pt. The search bar shares the title's outer leading anchor, but its visible text field has additional internal padding.
- `refreshTableKeepingPosition` explicitly restores the search field's first-responder status and selection after reloads. This must remain correct during typing, clearing, and keyboard dismissal.
- `App/NSRuleActionController.m` currently presents title, actions, details, then a separate copy section. Its copy label is set both during cell creation and when the temporary “Copied” feedback resets.
- `changelog.md` uses descending `# version` headings and concise hyphen bullets. Its newest existing entry is `2.4.8`.

## Implementation order

### 1. Set release metadata and fix CI package filenames together

Files: `control`, `.github/workflows/build.yml`, and the three `Resources/Info.plist` files under `App`, `FilterData`, and `FilterControl`.

1. Change `control` to `Version: 2.5.1`, retaining the package identifier `com.eolnmsuk.netshield`.
2. Run the existing `scripts/sync_version.py` during implementation to synchronize all three `CFBundleShortVersionString` values. Preserve the existing relationship between `CFBundleVersion` and `NSEngineVersion`; these UI and filename changes do not require changing the filtering engine version.
3. Implement the filename change in the GitHub workflow immediately after successful Theos packaging. Keep Theos's normal architecture-based output as the source and rename that exact file to `${PACKAGE_ID}_${PACKAGE_VERSION}_${PACKAGE_VARIANT}.deb`.
4. Populate `PACKAGE_VERSION` from the current `control` file's `Version` field on every build using the existing `scripts/sync_version.py --github-env` step. Use that same value in the source filename, renamed filename, extraction path, and artifact-upload path. Future version bumps must require no filename-related workflow or Makefile edits. Do not substitute a hardcoded version, Git tag, branch name, or workflow run number. Use the existing matrix variable for the variant: the rootful job has an empty `THEOS_PACKAGE_SCHEME` but an explicit `PACKAGE_VARIANT=rootful`.
5. Check that the exact source package exists, rename it, and check the destination. Avoid wildcard selection that could pick up an old package.
6. Update raw extraction and artifact upload to consume the renamed path. Keep artifact display names distinct from the contained `.deb` filename.
7. Retain the existing package architecture values (`iphoneos-arm`, `iphoneos-arm64`, and `iphoneos-arm64e`), staging paths, signatures, and package-content validation. Renaming the downloadable file must not alter Debian metadata.

Completion criteria: each matrix job uploads `${PACKAGE_ID}_${PACKAGE_VERSION}_${PACKAGE_VARIANT}.deb`, where `PACKAGE_VERSION` exactly matches the current `control` version, and all downstream verification reads that same file. This yields the listed 2.5.1 filenames for this release and automatically follows subsequent version bumps. The root Makefile can retain its existing packaging hooks because the requested GitHub output naming is handled in the workflow.

### 2. Unify dashboard headers and Clear-button layout

Primary file: `App/NSDashboard+Table.m`.

1. Establish one shared header-title font and styling path for both currently custom and currently default dashboard headers. Use a 17 pt base system font scaled with `UIFontMetrics`, with Dynamic Type enabled and the existing adaptive secondary-label color.
2. Set the visible headings explicitly to:
   - `FIREWALL`
   - `WAITING FOR YOUR DECISION`
   - `NOTIFICATIONS`
   - `CONFIGURATION`
   - `GLOBAL RULES`
   - `APP RULES`
   - `SYSTEM RULES`, when applicable
   - `RECENT ACTIVITY`
3. Rename only the Reset Settings section heading to `CONFIGURATION`. Preserve the distinct reset-action labels, confirmation messages, and behavior inside that section.
4. Preserve the existing Global Rules grouping: its heading belongs to `NSDashboardSectionAddGlobalRule`; the following rules section is intentionally untitled. Keep the support/version text separate from section-title styling.
5. Use automatic header sizing and multiline titles so long uppercase headings fit at larger text sizes. Replace the current title-to-button bottom offset with alignment that accommodates the larger title independently of the compact button.
6. Align each visible Clear button's trailing edge with the outer trailing edge of the adjacent inset-grouped content. Derive the position from the table's actual safe-area/grouped-content geometry rather than accumulating another fixed margin inside the header. Apply the same rule to Global Rules, App Rules, Recent Activity, and conditional System Rules.
7. Reduce the visible Clear button height by 25%: at the current 44 pt baseline, target 33 pt. Retain the existing Clear font calculation and size. Adjust vertical padding and height constraints together; reducing padding alone would leave the current 44 pt minimum in effect.
8. Keep an adequate touch area using a transparent surrounding control area where necessary. Allow additional visual height at accessibility text sizes when required to avoid clipping the unchanged text.
9. Retain each button's accessibility label, enabled state, section mapping, confirmation dialog, and clear operation. Account for the cached Recent Activity header when layout or text-size traits change.

Completion criteria: every named heading has the same scaled font and uppercase wording; Clear buttons share the requested trailing alignment and are visibly 25% shorter at the default text size without changing their font.

### 3. Align and relabel the Recent Activity search field

Primary file: `App/NSDashboard+Table.m`.

1. Change the empty-field placeholder to `Search recent connections` and keep its accessibility description consistent with its purpose.
2. Align the visible rounded search text field's leading edge with the leading edge of `RECENT ACTIVITY`. Aligning only the outer `UISearchBar` is insufficient because UIKit adds internal field padding.
3. Use the public `searchTextField` geometry after layout to account for the bar's internal inset, or a small layout helper if needed. Avoid private subviews, private keys, or a screen-width-specific offset.
4. Preserve the field's usable width and trailing alignment with the surrounding content. Recalculate layout when bounds, safe area, or text size changes, without repeatedly accumulating offsets.
5. Keep the existing query matching, activity grouping, autocapitalization, and autocorrection settings.

Completion criteria: the field's visible left edge matches the section title on supported layouts, and an empty query displays the exact new placeholder.

### 4. Implement keyboard dismissal and focus-safe search clearing together

Files: `App/NSDashboard.m`, `App/NSDashboard+Table.m`, and `App/NSDashboard+Internal.h`; a small helper class only if the public UIKit control customization requires it.

1. Add a single dashboard action that dismisses search editing without clearing the query. Reuse it for outside taps and the keyboard accessory.
2. Set the dashboard table's `keyboardDismissMode` to `UIScrollViewKeyboardDismissModeOnDrag` so beginning a scroll dismisses the keyboard.
3. Add outside-tap handling that excludes the search field and its descendants. Set the recognizer not to cancel ordinary touches, so tapping a row, switch, Clear button, or empty area both dismisses the keyboard and permits the original interaction.
4. Cover dashboard navigation-bar actions as well, including refresh, so tapping outside the search field does not leave the keyboard active. Keep gesture handling scoped to this dashboard and avoid interfering with presented sheets.
5. Attach a native `UIToolbar` input accessory containing flexible space and a Done button. It must remain available for both empty and nonempty queries and invoke the same dismissal action.
6. Make the x action explicitly clear the field and `activityQuery` through one update path, then refresh the filtered results while preserving the prior editing state.
7. Avoid replacing the search text field's internal delegate, which UIKit uses to implement `UISearchBar`. If the built-in clear button cannot preserve focus through supported callbacks, use an owned, accessible clear button in the public text field's `rightView`, disable the built-in clear button, and match the native clear appearance and visibility for a nonempty query. Its action must not request focus when the field was inactive.
8. Review `refreshTableKeepingPosition` as part of the same edit. Preserve first responder and caret selection during ordinary typing and visible-keyboard clearing, but suppress focus restoration after an intentional dismissal or an inactive-field clear. Avoid delayed callbacks that unconditionally reopen editing.
9. Keep the cached search field and header stable across monitor refreshes. Synchronize any custom clear-button visibility with text changes, including programmatic clearing.

Completion criteria:

| Interaction | Expected result |
| --- | --- |
| Tap the search field | Keyboard opens normally. |
| Type a query | Results filter; keyboard and caret remain stable through refreshes. |
| Tap outside the field | Keyboard dismisses; the tapped control still works. |
| Begin scrolling | Keyboard dismisses; the query remains intact. |
| Tap Done with an empty or nonempty query | Keyboard dismisses; the query remains intact. |
| Tap x while keyboard is hidden | Query clears; full recent results return; keyboard stays hidden. |
| Tap x while keyboard is visible | Query clears; full recent results return; keyboard stays visible. |
| Receive a periodic refresh after dismissal | Keyboard stays hidden. |

### 5. Move and rename the connection-copy action

Primary file: `App/NSRuleActionController.m`; inspect `App/NSDashboard.m` call sites to retain the Recent Activity scope.

1. For controllers with `clipboardText`, arrange the sheet as title/process identity, rule/action choices, copy action, then connection/process detail rows. Place the copy action immediately above the details and below the existing choices.
2. Keep the controller's current layout for app-rule and permission sheets without clipboard content. Use explicit section mapping or helper methods so section counts, row counts, cell rendering, selection handling, and footer placement agree when the copy section moves.
3. Keep the explanatory message associated with the details after remapping sections, rather than accidentally attaching it to the new copy section through the existing hardcoded section index.
4. Set the normal label to `Copy connection details` both when creating the cell and when resetting the temporary `Copied` feedback.
5. Preserve `NSActivityClipboardLine(connection)` as the copied payload, including the full process identity and the existing single-line format. Retain the accessibility announcement and keep the sheet open after copying.
6. Retain rule selection, selected-rule styling, Add Custom Rule, and dismissal behavior. Include connections without an identified process in the focused manual check.

Completion criteria: opening a Recent Activity connection places `Copy connection details` directly before its detail rows; copying and feedback still work, and unrelated action sheets retain their layout.

### 6. Add the 2.5.1 changelog entry

File: `changelog.md`.

1. Prepend `# 2.5.1`, a blank line, and concise hyphen bullets using the existing action-oriented style.
2. Cover variant-based package filenames; the moved and renamed copy action; search alignment and placeholder; keyboard dismissal and visibility-preserving clearing; compact, aligned Clear buttons; and uniform uppercase headings including CONFIGURATION and SYSTEM RULES.
3. Describe the final implemented behavior, including the confirmed x-button behavior. Preserve all historical entries and do not invent entries for the existing gap between 2.4.8 and 2.5.1.

### 7. Perform focused verification after implementation

These checks are future implementation steps, not work to run while creating this plan.

1. Review the final diff for the requested scope, exact strings, all three output paths, synchronized release versions, and accidental unrelated edits. Run `git diff --check`.
2. Run the existing metadata/package validation for the affected schemes and the repository's Objective-C formatting check using its pinned formatter. Avoid adding tests that merely assert label strings or mirror layout code.
3. Use one normal run of the existing GitHub build matrix to compile all variants and execute its existing checks. Retain the workflow's existing packaging, signing, entitlement, and native regression checks; do not repeatedly rerun passing checks without a new change or failure.
4. Inspect the resulting artifact filenames and extracted package metadata to confirm that the filename uses the variant and that both its version and the package's internal version exactly match the current `Version` field in `control`. Confirm by inspecting the metadata flow that a subsequent control-file version bump automatically changes all three filenames without editing filename templates. Retain the correct internal package architecture.
5. Perform a focused UI pass on a suitable iOS runtime/device: the keyboard interaction table above, copy placement/payload/feedback, all headings, and Clear-button sizing/alignment. Include System Rules shown and hidden, empty and populated activity, and a periodic monitor refresh during and after editing.
6. Check narrow and wider layouts, default and larger Dynamic Type, and light/dark appearance for wrapping, clipping, and alignment. Verify the Done accessory with an empty query.
7. If a required macOS/Theos build or iOS device check is unavailable, report that specific unverified behavior rather than treating source inspection as a successful runtime test.

## Expected implementation footprint

- Release metadata: `control` and three synchronized `Info.plist` files.
- GitHub package naming: `.github/workflows/build.yml`.
- Dashboard presentation and search behavior: `App/NSDashboard+Table.m`, `App/NSDashboard.m`, and declarations/state in `App/NSDashboard+Internal.h` as needed.
- Connection action ordering and labels: `App/NSRuleActionController.m`.
- Release notes: `changelog.md`.
- Add a helper source file or update `App/Makefile` only if required by the chosen UIKit implementation; avoid broad restructuring for these changes.

The order resolves release naming first, establishes shared header geometry before aligning the search field, handles keyboard and clear-button focus together, and writes release notes once the behavior is final. No product files are changed as part of preparing this plan.

# Hoarfrost

A menu bar manager forked from Thaw (itself a fork of Ice). The point of the
fork: instead of one hidden section, you get any number of named groups, each
with its own control icon, reveal style and hotkey. GPLv3, same as both parents.

## Where we are

- Base: Thaw `1.3.0-beta.1`, the last release that supports macOS 14 and 15.
  Full Thaw and Ice history is in this repo (`thaw` and `ice` remotes, Ice tags
  prefixed `ice-`).
- Branch `xcode16-build` makes 1.3 compile on Xcode 16.4 / macOS 15 by gating
  macOS 26 SDK symbols on `#if compiler(>=6.2)`. Debug build succeeds.
- Preston's machine: macOS 15.7.1, Xcode 16.4. Thaw 2.0 needs Xcode 26 so it
  cannot be built here. That is why 1.3 is the base and not 2.0.

## Facts that shape the design

- The only OS specific capability is capturing images of menu bar windows.
  Everything else (sections, settings, hotkeys, control items, panels) is plain
  AppKit and SwiftUI and identical on 14 through 26.
- The 14/15 call `CGWindowListCreateImageFromArray` and the 26 call
  `SLWindowListCreateImageFromArray` (private SkyLight, loaded via `dlsym`)
  have the same signature. `SLWindowListCreateImageFromArray` also exists on
  macOS 15 (verified with dlsym on this machine), so the SkyLight path can be
  tested on Sequoia today.
- Thaw 2.0 did the speed work we want: `LayoutSolver` and `LayoutReconciler`
  (pure planners for batched moves), `AXItemActivator` (click via accessibility
  actions instead of synthetic mouse events), `ClickReactionVerifier`,
  ScreenCaptureKit for on screen items with rate limiting. These live in
  `Thaw/MenuBar/MenuBarItems/` at tag `2.0.0-rc.5` and are candidates for
  backporting, since they do not depend on the 26 SDK.
- Thaw 2.0 commit `f21a41a1` is the removal of the 14/15 code paths. Useful as a
  reverse map of everything that is OS specific.
- The current section model is a fixed enum: `MenuBarSection.Name` with
  `visible`, `hidden`, `alwaysHidden`. It is referenced in about 16 files,
  most heavily `MenuBarItemManager.swift` (33 uses) and
  `MenuBarItemImageCache.swift` (9). Replacing it with dynamic groups is the
  core refactor.

## Plan

### 1. Capture backend seam (done, needs runtime testing)
- `Thaw/Utilities/WindowCaptureBackend.swift`: `protocol WindowCaptureBackend`
  with `CGWindowListCaptureBackend` (14+) and `SkyLightCaptureBackend`
  (dlsym, works on 15 and 26).
- Picked once at first use in `ScreenCapture.backend`: SkyLight when the
  symbol resolves, else CGWindowList. Override with
  `defaults write <bundle id> CaptureBackend skyLight|cgWindowList|automatic`.
- Callers did not change. `captureScreenBelowWindow` (overlay panel only)
  still uses `CGWindowListCreateImage` directly; move it behind the backend
  when the 26 build needs it.
- Still to do: run the app with each backend on Sequoia and compare Ice Bar
  images; surface the override in the Advanced settings pane.

### 2. Dynamic sections (in progress, branch `groups`)
Done, builds, not yet run:
- `MenuBarSection.Name` is a value with `id`, `rank`, `displayName`. Equality is
  by id. `Name.configured` is a live snapshot of the configured sections so
  code off the main actor sees the same list; `allCases` returns it.
- `SectionsConfiguration` persists hidden sections (key `SectionsConfiguration`).
  Defaults are the old `hidden` and `alwaysHidden`, with their original control
  item autosave names and hotkey action ids, so existing users see no change.
- `MenuBarManager` adds, renames, reorders and removes sections. Removal moves
  the section's items into the next shallower section first
  (`MenuBarItemManager.relocateItems(from:)`).
- The manager models dividers as `ControlItemSet.dividers` ordered by rank.
  Classification counts dividers left of an item. Destinations come from
  `leftmostDestination(in:)` and `rightmostDestination(in:)`.
- `HotkeyAction.toggleSection(id:)` plus per section recorders in Settings.
- Settings pane "Sections" editor: add, rename, up, down, remove.

Known limits to fix next:
- Profiles still save and apply three sections only (`itemOrder["visible"]`
  and friends in the manager's full sort code). Custom section items are left
  where they are when a profile is applied.
- Show on hover and scroll gestures in `HIDEventManager` still target the two
  default sections. Custom sections open by click or hotkey.
- The always hidden section keeps its advanced toggle; custom sections are
  always in the menu bar.
- Dropdown rows only left click. Right click on a row is not possible in an
  NSMenu; consider an Option modifier later.
- Show on hover and scroll still open rank 1 only.

### 2b. Reveal styles and the combined dropdown (done, builds, not yet run)
- `SectionRevealStyle`: automatic (follow the display's Ice Bar setting),
  push, bar, menu. Stored per section in `SectionDefinition.revealStyle`,
  picked in the Sections editor.
- `SectionDropdownMenu` builds an NSMenu with a row per item (captured image
  or app icon, item name). Choosing a row clicks the real item through
  `temporarilyShow`, like the Ice Bar.
- Toggle "Clicking the menu bar icon opens one dropdown with every section":
  the app icon opens a menu with a submenu per section. Since collapsed
  dividers sit offscreen, this gives a single visible icon.

Manual test plan (quit Ice first, then run the Thaw scheme):
1. Fresh launch shows the same three sections and dividers as before.
2. Settings, Menu Bar Layout, Sections: Add Section. A third divider appears.
   Drag an item into it in the layout bar, click its divider, it expands.
3. Rename it, assign a hotkey in Hotkeys, use the hotkey.
4. Move it up so it becomes rank 1. Dividers reorder in the menu bar and the
   right items stay with the right sections.
5. Remove it. Its items move into the neighbouring section.
6. Quit and relaunch. Everything above persists.
7. Set a section's style to Dropdown menu, click its divider, pick an item.
8. Turn on the combined dropdown toggle and click the app icon.

### Shelved but cool
- Split halves: the left and right half of the empty menu bar space open
  different sections. Built and working (hidden in the picker, the code is
  in `HIDEventManager` and `EmptyBarClickBehavior.split`), but an invisible
  boundary confused even its inventor. Revisit with a visual hint, like a
  faint divider or highlight of the half under the cursor while hovering.

### 2c. Raw mode (built)
- Empty bar click behavior is a setting: toggle the first section, cycle
  through sections, or split halves. Cycle opens instantly by default; a
  toggle makes it wait for multi clicks instead.
- Right click on empty space lists every section with its items.
- Dropdowns pop at the mouse after the button releases. The release wait is
  the floor on dropdown latency; going lower means eating the mouse up in an
  event tap, which is recorded here as a possible later experiment.

### 3. Speed (first piece done)
- Backported Thaw 2.0's accessibility click delivery (`AXItemActivator`,
  `ClickReactionVerifier`, flag `UseAXClickDelivery`, default on). Left
  clicks try AXShowMenu then AXPress and fall back to the synthetic click.
  If some item misbehaves, `defaults write <bundle id> UseAXClickDelivery -bool NO`
  turns it off.
- Backport from 2.0 in this order: `AXItemActivator` (click without fake mouse
  events), `LayoutSolver` plus `LayoutReconciler` (batch moves, skip items
  already in place), image cache rate limiting.
- Then measure: time from control item click to items visible. Trim the fixed
  `uiSettleDelay` (300 ms) and per event sleeps (25 ms) to the minimum the
  window server tolerates, with the adaptive timeouts 1.3 already has.
- Menu style reveal moves nothing, so it is instant by construction. Push and
  bar styles are where the timing work matters.

### 4. Later
- Rename bundle, app name and identifiers from Thaw to Hoarfrost once the
  group model is in, so upstream cherry picks stay easy until then.
- Xcode 26 build on a Tahoe machine to confirm the `compiler(>=6.2)` branches.

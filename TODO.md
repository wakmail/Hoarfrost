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

### 1. Capture backend seam
- `protocol WindowCaptureBackend` with `captureWindows(ids, bounds, options)`
  and `captureBelowWindow`.
- `CGWindowListBackend` (14+, deprecated API, current 1.3 code) and
  `SkyLightBackend` (dlsym, Thaw 2.0 `Bridging.captureWindowsImage`).
- Pick at runtime: SkyLight when the symbol resolves, else CGWindowList.
  Advanced setting to force one for debugging.
- `ScreenCapture` becomes a thin facade over the chosen backend, so callers
  in `MenuBarItemImageCache` do not change.

### 2. Dynamic groups (replaces the fixed three sections)
- `MenuBarGroup`: id, name, icon, reveal style, hotkey, order.
- Reveal styles: `push` (Ice style horizontal expand), `bar` (Ice Bar floating
  panel), `menu` (real NSMenu dropdown with item image plus app name per row).
- Global option: one control icon for all groups (single menu with sections,
  or single bar with labelled rows) or one control icon per group. Both must
  work, per group override allowed.
- Persistence: item to group assignment keyed by the existing stable item
  identifiers. Migration: `visible` stays ungrouped, `hidden` and
  `alwaysHidden` become two default groups so existing Thaw and Ice settings
  import cleanly.
- Refactor path: introduce `MenuBarGroup` alongside `MenuBarSection.Name`,
  move the manager over one call site at a time, delete the enum last.

### 3. Speed
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

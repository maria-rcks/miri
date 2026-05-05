# Feature branch change log

Branch: `feature/local`  
Base branch: `main`  
Merge-base: `71cbac9e694adb95bd30d6c327f9f7bfd414a360`  
Range reviewed: `71cbac9..HEAD`  
Generated: 2026-05-05

## Executive summary

This branch turns Miri from a headless-style window manager into a more user-facing macOS accessory app with a menu bar status item, settings editor, richer configuration, better persistence, and several stability fixes around hidden, minimized, fullscreen, destroyed, and transient windows. It also changes the default keybindings from Command-based shortcuts to left Option-based shortcuts and adds packaging support for a signed app bundle.

Overall diff: 8 files changed, 2004 insertions, 150 deletions.

## Files changed

- `.gitignore`
  - Ignores `dist/` build output.
- `Sources/Miri/Config.swift`
  - Adds animation throttling settings.
  - Adds workspace bar settings.
  - Changes default keybindings from `cmd` to `lalt`.
  - Adds validation/clamping for new config values.
- `Sources/Miri/Miri.swift`
  - Adds status/menu integration APIs.
  - Adds workspace bar data APIs.
  - Improves keybinding modifier matching.
  - Preserves minimized, hidden, and fullscreen window layout state.
  - Reduces layout churn and animation work.
  - Improves persistent layout snapshot matching.
  - Handles destroyed windows immediately.
  - Filters Chromium transient/picture-in-picture windows.
  - Adds AX/debug logging helpers.
- `Sources/Miri/SettingsWindowController.swift`
  - New AppKit settings window for editing config.
- `Sources/Miri/StatusMenuController.swift`
  - New menu bar status/menu controller.
- `Sources/Miri/main.swift`
  - Starts Miri as an accessory `NSApplication` and runs the app loop.
- `miri.config.json`
  - Updates sample/default config values, keybindings, animation defaults, workspace bar options, and width presets.
- `scripts/package-app.sh`
  - New script for building and signing a macOS app bundle.

## Detailed changes by area

### 1. Default keybindings moved to left Option

- Default shortcuts now use `lalt`/left Option instead of `cmd`.
- The excluded capture shortcut default changed from `cmd+shift+5` to `lalt+shift+5`.
- Key event parsing now considers generic `alt`, `lalt`, and `ralt` candidates so side-specific Option bindings can resolve from real macOS key events.

### 2. Menu bar app behavior

- Miri now imports AppKit in `main.swift`, creates `NSApplication.shared`, sets activation policy to `.accessory`, and runs the app event loop.
- A new status menu shows current Miri state, including:
  - active workspace,
  - focused window,
  - current width percentage when available.
- Menu actions were added for:
  - opening the config file,
  - reloading config,
  - rescanning windows,
  - opening Settings,
  - quitting cleanly.

### 3. Settings window

A new `SettingsWindowController` adds a tabbed AppKit settings UI. It covers:

- General settings.
- Layout settings.
- Focus settings.
- Animation settings.
- Trackpad settings.
- Window rules.
- Keybindings.

The settings editor can:

- Save config changes back to JSON.
- Reload changes immediately after saving.
- Reuse one settings window instance when reopened.
- Prefill rule creation from currently open apps.
- Duplicate and reorder window rules.
- Edit command keybindings and excluded shortcuts.
- Validate duplicate keybindings before saving.
- Show success/error alerts.

### 4. Workspace bar in the status item

The branch adds a configurable menu bar workspace visualization:

- Active workspace is rendered as a status bar image.
- App icons are shown for workspace windows.
- The focused window is highlighted.
- Overflow indicators are supported.
- Occupied workspaces are summarized in the menu bar/status menu.
- The status menu now includes a `Workspaces` section with occupied spaces and app names.

New config options:

- `workspace_bar_highlight_color`
- `workspace_bar_visible_icon_count`
- `workspace_bar_overflow_style`

New overflow styles:

- `plus_count`
- `dots_count`
- `chevron`
- `none`

### 5. Animation/layout churn reduction

New config options:

- `animation_fps`
- `animation_pixel_threshold`

Behavior changes:

- Animation frame updates can be throttled by FPS.
- Tiny frame changes can be skipped using the pixel threshold.
- Applied frames and visibility are cached to avoid redundant AX operations.
- Only windows involved in focus changes are animated where applicable.
- Self-triggered focus notifications are temporarily suppressed.
- Persistent layout snapshot writes are debounced instead of written immediately every time.
- Sample config disables animations by default by setting animation durations to `0`.

### 6. Minimize, hide, and fullscreen stability

Window state preservation was improved across macOS window state transitions:

- Minimized and hidden windows are tracked separately during rescans.
- Hidden apps and miniaturized windows are ignored during discovery.
- AX minimize/show notifications trigger rescans so focus and layout stay stable.
- Restored minimized/hidden windows recover saved width and are reinserted near the focused column.
- Fullscreen transitions remember each tiled window's:
  - workspace,
  - neighboring windows,
  - width ratio,
  - active/focus state.
- Windows exiting fullscreen are restored to prior layout position instead of being treated as new windows.
- Fullscreen frames are ignored during move/resize handling.

### 7. Focus visibility improvements

- The active column is revealed when moving focus horizontally.
- The active column is also revealed whenever focus changes.
- This keeps the focused column visible within the horizontal camera/strip viewport.

### 8. Persistent layout snapshot improvements

- Snapshots now save the effective `manualWidthRatio` from `widthRatio(for:)`.
- Restore matching now prefers exact window identity first.
- Fallback matching uses bundle ID or app name.
- When multiple snapshot entries could match, the closest workspace/column candidate is preferred.
- Snapshot writes are debounced to reduce disk churn.

### 9. Destroyed window handling

- AX destroyed notifications are handled immediately.
- Destroyed tiled and floating windows are removed as soon as the notification arrives.
- Layout is reprojected immediately.
- Focus is preserved for the active tiled window before a delayed rescan happens.

### 10. Chromium transient and Picture-in-Picture filtering

- Chromium `AXUnknown` subrole windows are ignored.
- Small Chromium popups and Picture-in-Picture windows are skipped during scans.
- Transient detection uses title, subrole, frame, and browser heuristics.
- Helium is included in the Chromium browser list.
- Deduplicated AX diagnostics are written to the debug log when debug logging is enabled.

### 11. Packaging and generated output

- `scripts/package-app.sh` builds a macOS `.app` bundle under `dist/`.
- The package script signs the bundle so the app has a stable identity for macOS permissions.
- `dist/` is ignored in Git.

### 12. Sample config changes

The bundled `miri.config.json` was updated to reflect the new branch defaults:

- `default_width_ratio` changed from `0.8` to `0.67`.
- `preset_width_ratios` changed to `[0.33, 0.5, 0.67, 1.0]`.
- Animation durations are set to `0` by default.
- New animation throttling settings were added.
- Keybindings were switched from `cmd` to `lalt`.
- Workspace bar settings were added.

## Commit-by-commit history

### `acf3591` — Use left Option for default keybindings

- Switched fallback and sample keybindings from `cmd` to `lalt`.
- Updated excluded capture shortcut override.
- Added generic/left/right Alt modifier matching.
- Updated width presets to default around `0.67` and include narrower ratios.

### `2b2abed` — Preserve tiled window state across minimize and app hide

- Tracks minimized and hidden windows separately during rescans.
- Restores windows with saved width and reinserts them near focused column.
- Ignores hidden apps and miniaturized windows in discovery.
- Responds to AX minimize/show notifications.
- Adds package script for signed app bundle.

### `ade72bc` — Ignore dist output directory

- Adds `dist/` to `.gitignore`.

### `3d3259b` — Reduce layout churn during focus and resize updates

- Adds `animation_fps` and `animation_pixel_threshold`.
- Skips tiny animation frame updates.
- Caches applied frame/visibility state.
- Animates only focus-change-related windows in some paths.
- Suppresses self-triggered focus notifications.
- Debounces persistent snapshot writes.
- Updates sample config to disable animations by default.

### `94b67f0` — Add a menu bar status menu for Miri

- Runs Miri as an accessory AppKit application.
- Adds menu bar status item/menu.
- Shows workspace, focused window, and width.
- Adds menu actions for config, reload, rescan, and quit.

### `bc495bd` — Reveal active column when moving focus horizontally

- Ensures horizontal focus moves bring the active column into view.

### `174f7ef` — Add a settings window for editing Miri config

- Adds tabbed AppKit settings UI.
- Exposes Settings from the status menu.
- Saves config to JSON and reloads immediately.
- Prefills rule creation from open apps.

### `7bae7bc` — Expand settings editor for keybindings and rule management

- Adds Keybindings tab.
- Allows editing command bindings and excluded shortcuts.
- Validates duplicate bindings.
- Adds rule duplicate/reorder actions.

### `c809c2b` — Add configurable workspace bar to the status menu

- Renders active workspace as a status bar image with app icons.
- Highlights focused window and shows overflow.
- Exposes workspace window data to the status menu.
- Adds config/settings support for workspace bar options.

### `de7b462` — Handle destroyed windows immediately

- Removes destroyed tiled/floating windows on AX destroyed notification.
- Reprojects layout immediately.
- Preserves focus before delayed rescan.

### `134c8ef` — Show occupied workspaces in the status bar

- Adds occupied workspace summaries.
- Shows inactive occupied workspace icons before the active window strip.
- Adds Workspaces section to status menu.

### `cc42e77` — Reveal active column when focus changes

- Extends active-column reveal behavior to general focus changes.

### `3ab58ed` — Improve persistent layout snapshot matching

- Saves effective manual width ratio.
- Restores by exact identity, then bundle ID/app name fallback.
- Chooses nearest workspace/column snapshot candidate.

### `fe2195e` — Preserve tiled windows across fullscreen transitions

- Remembers tiled window position, neighbors, width, and focus before fullscreen.
- Restores windows exiting fullscreen to their old layout position.
- Ignores fullscreen frames during move/resize handling.
- Rescans on transition events.

### `7af93d9` — Ignore transient Chromium popup windows

- Adds initial filtering for transient Chromium popup windows.

### `1fe00a6` — Ignore Chromium PiP and transient windows

- Skips `AXUnknown` subrole windows, Chromium popups, and Picture-in-Picture windows.
- Broadened title/subrole heuristics.
- Adds Helium to Chromium browser list.
- Adds deduplicated AX diagnostics for raw/discovered windows and notifications.

# Miri refactoring summary

Refactoring chat session: https://pi.dev/session/#b109e38490f0e70c93bca2a02e3b86b4

This document summarizes the refactoring work done to split the original `Sources/Miri/Core/Miri.swift` god object into focused source files.

## Goal

The original `Miri.swift` mixed nearly every application responsibility in one class/file:

- app lifecycle
- status/menu integration
- config reload
- event tap handling
- keybinding resolution
- trackpad camera/momentum
- command execution
- workspace navigation
- window discovery/classification
- window placement/removal
- layout projection/application
- animation
- hover focus
- transient system window recovery
- persistence/exit restoration
- fullscreen/minimized restoration
- manual resize handling
- AX observer callbacks
- debug logging

The refactor keeps `Miri` as the central coordinator, but moves cohesive behavior into separate extension/helper files.

## Result

`Sources/Miri/Core/Miri.swift` was reduced from roughly **4135 lines** to roughly **160 lines**.

It now primarily contains:

- core shared state
- `start()`
- Accessibility permission request
- workspace app notification registration
- termination signal handling
- cleanup watcher startup


## Folder layout

The refactored source is now grouped by responsibility:

```text
Sources/Miri/Core/          coordinator, commands, core models, status providers
Sources/Miri/Config/        config model and effective setting accessors
Sources/Miri/Input/         keyboard/event tap input and keybinding resolution
Sources/Miri/Trackpad/      raw trackpad backend and Miri trackpad camera
Sources/Miri/Layout/        layout projection, geometry, application, animation
Sources/Miri/Windows/       window discovery, placement, lookup, transient windows, AX observer, resize
Sources/Miri/Persistence/   persistent layout and exit/crash restoration
Sources/Miri/UI/Settings/   settings window UI
Sources/Miri/UI/StatusMenu/ status menu/workspace bar UI
Sources/Miri/Debug/         debug logging
Sources/Miri/System/        Accessibility and SkyLight system wrappers
```

## New/extracted files

### Keybindings

- `Sources/Miri/Input/KeybindingResolver.swift`

Extracted keybinding parsing, normalization, excluded keybinding matching, keyboard text extraction, and command lookup.

### Miri status/model structs

- `Sources/Miri/Core/MiriStatusModels.swift`

Extracted small status and internal state structs used by menus, workspace bar, trackpad settings, transient windows, and fullscreen restoration.

### Effective config settings

- `Sources/Miri/Config/MiriEffectiveSettings.swift`

Extracted computed config-derived settings such as animation duration, hover focus settings, trackpad settings, gaps, width presets, hide method, and debug logging.

### Debug logging

- `Sources/Miri/Debug/MiriDebugLogging.swift`

Extracted debug log writing and AX/window debug output helpers.

### Persistent layout

- `Sources/Miri/Persistence/MiriPersistentLayout.swift`

Extracted layout snapshot reading/writing/restoration and persistent window identity matching.

### Layout animation

- `Sources/Miri/Layout/MiriLayoutAnimation.swift`

Extracted layout animation timer, interpolation, easing curves, frame delta checks, animation frame application, and layout lock release.

### Layout geometry

- `Sources/Miri/Layout/MiriLayoutGeometry.swift`

Extracted strip geometry, scroll offset calculation, viewport inset helpers, visible-frame calculation, parked-frame calculation, and closest/most-visible column helpers.

### Window queries/rules

- `Sources/Miri/Windows/MiriWindowQueries.swift`

Extracted active/all/tiled window queries, width ratio resolution, rule lookup, behavior lookup, and trackpad/hover rule checks.

### Hover focus

- `Sources/Miri/Windows/MiriHoverFocus.swift`

Extracted mouse-move hover focus handling, hover target selection, edge trigger detection, delayed hover focus scheduling, hover suppression, and hover focus execution.

### Trackpad camera

- `Sources/Miri/Trackpad/MiriTrackpadCamera.swift`

Extracted trackpad gesture handling, camera seeding, camera movement, velocity conversion, momentum, render loop, settling, and trackpad camera cleanup.

### Commands/workspace operations

- `Sources/Miri/Core/MiriCommands.swift`

Extracted command dispatch, workspace focus/movement, column focus/movement, width preset cycling, width nudging, and layout state capture.

### Transient system windows

- `Sources/Miri/Windows/MiriTransientWindows.swift`

Extracted transient system window detection/recovery, open/save panel service detection, Chromium popup/PiP detection, and Chromium browser matching.

### Window lookup / AX helpers

- `Sources/Miri/Windows/MiriWindowLookup.swift`

Extracted tiled window lookup, element location lookup, AX attribute helpers, frame reading, and AX element equality.

### Window discovery

- `Sources/Miri/Windows/MiriWindowDiscovery.swift`

Extracted app activation/launched/terminated handlers, full rescan flow, AX window discovery, window manageability checks, fullscreen checks, and known-window classification.

### Window placement

- `Sources/Miri/Windows/MiriWindowPlacement.swift`

Extracted new/restored/floating window insertion, target workspace selection, workspace creation, removal, fullscreen state restore, minimized state restore, and trailing empty workspace management.

### Manual resize/fullscreen notifications

- `Sources/Miri/Windows/MiriManualResize.swift`

Extracted fullscreen transition handling, destroyed-window removal, manual width ratio updates, manual resize session tracking, resize suppression, and resize-end scheduling.

### Layout projection/application

- `Sources/Miri/Layout/MiriLayoutApplication.swift`

Extracted layout projection, layout item generation, active-column selection, trackpad camera workspace mapping, layout application, item frame/visibility application, floating visibility restoration, and window focusing.

### Status/menu/config integration

- `Sources/Miri/Core/MiriStatusProvider.swift`

Extracted status bar/workspace bar data providers, menu actions, settings window integration, config saving, available app list generation, rescan timer, periodic tick, and hot config reload.

### Event tap

- `Sources/Miri/Input/MiriEventTap.swift`

Extracted event tap installation, trackpad navigation installation/restart, cleanup watcher update, input configuration, key event handling, event tap disabled recovery, and the event tap callback.

### AX observer

- `Sources/Miri/Windows/MiriAXObserver.swift`

Extracted focused-window adoption, AX observer installation, AX notification handling, and the AX observer callback.

### Exit restoration

- `Sources/Miri/Persistence/MiriExitRestoration.swift`

Extracted normal-exit window restoration and crash/kill restore snapshot writing.

## Ported main-branch work

After the refactor, selected changes from `main` were hand-ported instead of directly cherry-picked because this branch had a very different file layout.

Ported areas:

### Keybinding support

Main-branch keybinding improvements were adapted into:

- `Sources/Miri/Input/Input.swift`
- `Sources/Miri/Input/KeybindingResolver.swift`

This added support for:

- broader ANSI letter key codes
- punctuation keys
- arrow/navigation keys
- page up / page down
- function keys
- `fn` / Globe modifier
- MacBook `fn` navigation aliases, e.g. `fn+left` can match `home`
- expanded key name aliases such as `left-arrow`, `pgup`, `spacebar`, etc.

### Floating window stacking

Main's floating-window stacking fixes were adapted into:

- `Sources/Miri/System/SkyLight.swift`
- `Sources/Miri/Core/Miri.swift`
- `Sources/Miri/Core/Models.swift`
- `Sources/Miri/Layout/MiriLayoutApplication.swift`
- `Sources/Miri/Layout/MiriLayoutAnimation.swift`
- `Sources/Miri/Persistence/MiriExitRestoration.swift`
- `Sources/Miri/Persistence/Restoration.swift`

This added:

- `SkyLight.setLevel` support
- floating-window level restoration/raising
- delayed floating-window raise after layout/focus changes
- floating-window IDs in exit/crash restore snapshots
- cleanup restoration that resets alpha and window level

### Layout animation visibility

Main's animation visibility improvements were adapted into:

- `Sources/Miri/Core/Models.swift`
- `Sources/Miri/Layout/MiriLayoutAnimation.swift`

This added `startsVisible` / `endsVisible` tracking to `WindowMotion` so windows entering a layout animation can be revealed at the right point instead of flashing too early.

### Release packaging

Main's release packaging was added as:

- `.github/workflows/release.yml`
- `scripts/package-macos.sh`

The existing local helper was updated:

- `scripts/package-app.sh`

`package-app.sh` now delegates to `package-macos.sh`, while preserving the old local-dev behavior of leaving a directly openable app at:

```text
dist/Miri.app
```

`package-macos.sh` also produces a versioned DMG in `dist/`.

Main's older menu bar status menu commits were intentionally not ported because this branch already has the newer status/menu implementation under:

- `Sources/Miri/UI/StatusMenu/`
- `Sources/Miri/Core/MiriStatusProvider.swift`

## Build status

The project was built after each refactoring and porting batch.

Final verification:

```bash
swift build
```

Result:

```text
Build complete
```

## Notes

Most extractions were implemented as `extension Miri` files to preserve behavior while reducing file size and isolating domains. Some previously `private` members were relaxed to internal access so extensions in separate files can share coordinator state.

This refactor intentionally avoids changing runtime behavior. It is primarily structural: code was moved into focused files, with minimal logic changes.

# Animation revamp branch changes

This document summarizes the changes in this branch compared to `feature/local`.

## Summary

This branch replaces Miri's AX-per-frame animation work with a snapshot-based animation backend and keeps a non-animated `off` mode. The goal is smoother keyboard-driven column focus/movement, less AX/WindowServer churn, and fewer flickers when windows move in and out of the visible viewport.

## Major changes

### Snapshot animation backend

Added a compositor-backed snapshot animation path in:

- `Sources/Miri/Layout/MiriSnapshotAnimation.swift`

The snapshot backend:

- captures active tiled windows into `CGImage` snapshots
- renders snapshots in a transparent AppKit overlay window backed by `CALayer`
- hides real tiled windows underneath while the overlay animates
- applies final AX frames once at completion
- reveals real windows after the visual animation finishes

This avoids repeatedly resizing/moving real app windows through Accessibility APIs during animation frames.

### Retargetable animation sessions

Snapshot animation is now session-based instead of starting from scratch for every keyboard command.

When the user repeatedly sends focus left/right commands during an active animation, Miri now:

- keeps the snapshot overlay/session alive
- reads current presentation-layer frames
- retargets existing snapshot layers to the newest layout
- invalidates stale completion callbacks using generation counters
- only lets the latest layout request complete/reveal windows

This is intended to make rapid focus chains continue toward the final target instead of snapping, disappearing, or pausing between each step.

### Animation strategy simplification

`animation_strategy` now supports only:

- `snapshot`
- `off`

The previous selectable AX animation backends were removed from the UI/config surface:

- `smooth_ax`
- `snappy`

For backwards compatibility, old config values `smooth_ax` and `snappy` decode as `snapshot`.

### Focus sequencing fixes

Rapid keyboard focus changes exposed races between Miri's internal active-column state and delayed macOS AX focus notifications.

This branch adds:

- focus-request generation tracking
- keyboard focus authority timeout
- suppression of stale AX focus adoption during keyboard-driven focus chains
- serialization for focus commands when animation is disabled
- immediate focus-at-start behavior for snapshot animations only, without revealing the real window under the overlay

This helps prevent cases where quick focus commands land on an earlier/stale column.

### Workspace/window visibility stability

Added explicit inactive-workspace visibility tracking in:

- `Sources/Miri/Layout/MiriWorkspaceVisibility.swift`

This hides inactive workspace windows and tracks hidden IDs so they do not flicker or participate incorrectly in active workspace animations.

Snapshot-specific hidden-window tracking was also added so windows hidden under the overlay are restored reliably after completion/interruption.

### Accessibility frame application changes

Updated AX frame setting behavior in:

- `Sources/Miri/System/Accessibility.swift`

Notable changes:

- frame writes use a size → position → size sequence
- managed window frame writes can temporarily disable `AXEnhancedUserInterface`

These changes reduce resize/move glitches when Miri has to apply real AX frames.

### Animation timing support

Added:

- `Sources/Miri/Layout/MiriAnimationTimer.swift`

This introduces a `CVDisplayLink`-backed animation timer with a dispatch timer fallback. The snapshot backend is now the primary animation path, but this timer support remains part of the branch.

### Settings and docs

Updated:

- `README.md`
- `miri.config.json`
- `Sources/Miri/UI/Settings/SettingsWindowController.swift`

Defaults now prefer:

```json
"animation_strategy": "snapshot",
"animation_fps": 60,
"animation_pixel_threshold": 0.5
```

The settings UI strategy dropdown now shows only `snapshot` and `off`.

## Files added

- `Sources/Miri/Layout/MiriAnimationStrategy.swift`
- `Sources/Miri/Layout/MiriAnimationTimer.swift`
- `Sources/Miri/Layout/MiriSnapshotAnimation.swift`
- `Sources/Miri/Layout/MiriWorkspaceVisibility.swift`
- `docs/pull-request-draft.md`

## Validation

Validated locally with:

```bash
swift build
```

## Notes

Snapshot animation deliberately focuses at animation start only for the snapshot backend. Non-animated mode still applies the final layout first and then focuses, because there is no overlay hiding intermediate AX state.

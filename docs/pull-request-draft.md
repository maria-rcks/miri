# Pull request draft

## Suggested title

```text
Idea for animating efficiently and smoother than bruteforcing AX IPCs
```

## Suggested pull request body

```markdown
## Disclaimer

I do **not** recommend merging this PR as-is.

This branch contains a substantial animation/backend experiment plus several focus, visibility, and AX sequencing fixes. It should be treated as a reference implementation and design sketch for a smoother animation path, not as a small ready-to-merge patch.

The main idea is to avoid brute-forcing macOS Accessibility IPCs every frame. Instead, Miri captures window snapshots, animates those snapshots with Core Animation, and applies real AX window frames only at stable synchronization points.

Discussion / implementation session:
https://pi.dev/session/#862e24e3d724e5cdac8c7ac792b99c16

More details about the changes in this PR branch are documented in the `docs` folder, especially:

- `docs/animation-revamp-branch-changes.md`

## Summary

This PR experiments with a snapshot-based animation backend for Miri.

The previous AX animation approach tried to move/resize real app windows frame-by-frame through Accessibility APIs. That is inherently janky on macOS: AX writes are IPC-heavy, app-dependent, not atomic across size/position, and not synchronized with WindowServer/compositor frames.

This branch adds a compositor-backed snapshot mode:

1. Capture tiled window images.
2. Show them in a transparent overlay window as `CALayer`s.
3. Hide the real windows underneath.
4. Animate the snapshot layers.
5. Apply final AX frames once.
6. Reveal the real windows behind the overlay.
7. Tear down/reset the overlay.

The branch also removes the old selectable `smooth_ax` and `snappy` animation strategies from the public config surface, leaving only:

- `snapshot`
- `off`

Legacy config values `smooth_ax` and `snappy` are decoded as `snapshot` for compatibility.

## Motivation

The old AX animation strategy was expensive and unreliable because it repeatedly drove app windows through Accessibility APIs:

- high AX IPC volume during every animation frame
- non-atomic size/position updates
- app-specific latency and repaint behavior
- no compositor/vsync synchronization
- visible flicker when windows enter/leave the viewport
- bad behavior during rapid keyboard command chains

The snapshot backend is intended to make animations smoother and less battery-heavy by moving most per-frame work into Core Animation.

## Highlights

### Snapshot animation backend

Added:

- `Sources/Miri/Layout/MiriSnapshotAnimation.swift`

The backend captures tiled windows with `CGWindowListCreateImage` and animates them in a transparent overlay window.

Real windows are hidden below the overlay while snapshots animate, then restored after final layout is applied.

Snapshot capture uses:

```swift
[.bestResolution, .boundsIgnoreFraming]
```

so snapshot dimensions better match the real window bounds.

### Retargetable snapshot sessions

Rapid keyboard focus commands are handled by retargeting an active snapshot session instead of cancelling and rebuilding animation state every time.

During an active snapshot animation, new focus left/right commands:

- keep the overlay/session alive
- read current presentation-layer frames
- retarget existing snapshot layers toward the latest layout
- invalidate stale completion callbacks with generation counters
- only allow the latest layout request to reveal real windows

This makes command chains feel like one continuous movement rather than a sequence of disconnected animations.

### Active tiled windows are snapshotted together

The backend snapshots active tiled windows as a group, including offscreen/hidden columns, so later retargets can animate windows that were not visible at the beginning of the chain.

This avoids cases where focusing further right/left would have no snapshot for the newly targeted offscreen column.

### Animation strategy simplification

Updated config/settings/docs so animation strategy is now:

```json
"animation_strategy": "snapshot"
```

or:

```json
"animation_strategy": "off"
```

Removed public `smooth_ax` and `snappy` backend choices.

### Focus sequencing fixes

This branch adds several fixes for rapid focus commands:

- focus request generation tracking
- keyboard focus authority timeout
- stale AX focus notification suppression
- focus command serialization when animation is disabled
- immediate focus-at-start for snapshot animations only

Snapshot mode focuses the target window at animation start without revealing the real window under the overlay. Non-animated mode keeps the safer behavior: apply final layout first, then focus.

### Stale completion protection

Snapshot completions are guarded by layout/session generations. If a new focus/layout request arrives near the end of an animation, the old completion callback no longer applies stale layout or tears down the current visual state.

This fixes cases where focus changed logically but the visual snapshot state was left stale.

### Workspace and visibility stability

Added:

- `Sources/Miri/Layout/MiriWorkspaceVisibility.swift`

Inactive workspace windows are explicitly hidden/tracked so they do not flicker or participate in active workspace animations.

Snapshot-hidden windows are also tracked and restored defensively on completion/interruption.

### AX frame application improvements

Updated:

- `Sources/Miri/System/Accessibility.swift`

Changes include:

- applying AX frames as size → position → size
- temporarily disabling `AXEnhancedUserInterface` around managed frame changes

These help reduce resize/move glitches for the unavoidable real AX commits.

### Animation timing support

Added:

- `Sources/Miri/Layout/MiriAnimationTimer.swift`

This provides a `CVDisplayLink`-backed timer with a dispatch timer fallback. The snapshot backend is now the preferred path, but this remains useful infrastructure for animation timing.

## Permission note

Snapshot animations require Screen Recording permission because Miri captures window images for the animation overlay.

The README now documents that Miri may require:

- Accessibility
- Input Monitoring
- Screen Recording, for snapshot animations

## Config/UI changes

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

The settings UI strategy dropdown now shows only:

- `snapshot`
- `off`

## Files added

- `Sources/Miri/Layout/MiriAnimationStrategy.swift`
- `Sources/Miri/Layout/MiriAnimationTimer.swift`
- `Sources/Miri/Layout/MiriSnapshotAnimation.swift`
- `Sources/Miri/Layout/MiriWorkspaceVisibility.swift`
- `docs/animation-revamp-branch-changes.md`

## Validation

Tested locally:

- [x] `swift build`

## Notes / risks

This is still experimental.

Known areas that deserve extra review/testing:

- Screen Recording permission flow and failure behavior
- multi-monitor behavior
- fullscreen/native Spaces edge cases
- windows that cannot be captured by `CGWindowListCreateImage`
- interaction with apps that repaint or reorder windows aggressively on focus
- AppKit overlay lifetime and cleanup
- rapid command chains across many offscreen columns

The intended value of this branch is the architectural direction: avoid per-frame AX IPCs and use snapshots/Core Animation for visual motion.
```

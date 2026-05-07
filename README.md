<div align="center">

# miri

[![License](https://img.shields.io/badge/license-MIT-111111?style=flat-square)](./LICENSE)
[![GitHub](https://img.shields.io/badge/github-maria--rcks%2Fmiri-111111?style=flat-square&logo=github)](https://github.com/maria-rcks/miri)
[![Ko-fi](https://img.shields.io/badge/ko--fi-maria__rcks-111111?style=flat-square&logo=kofi)](https://ko-fi.com/maria_rcks)

<img src="./assets/repo/miri-demo.gif" alt="miri macOS window layout preview" width="1000" />

_Niri-ish, keyboard-first window manager for macOS._

</div>

## Install

Build and run from source:

```bash
git clone https://github.com/maria-rcks/miri.git
cd miri
swift run miri
```

For a release build:

```bash
swift build -c release
.build/release/miri
```

To build a local macOS disk image:

```bash
scripts/package-macos.sh --version 0.1.0
open dist/Miri-0.1.0-*.dmg
```

miri needs Accessibility permission, and the event tap may also need Input
Monitoring permission. If you run it from a terminal, macOS may ask for the
terminal app itself to get those permissions.

## What it does

- Keeps a Niri-like virtual layout of workspaces and columns on macOS.
- Tiles normal app windows with Accessibility APIs instead of acting as a
  compositor.
- Makes each column `0.8` screen widths by default, so the next column can peek
  in while you move sideways.
- Centers the focused column when possible, while keeping the first column
  pinned to the left edge.
- Tracks `Cmd+Tab`, app launches, app exits, manual window resizes, and focused
  windows so the model follows macOS instead of fighting it.
- Supports app rules for tiled, floating, and ignored windows.
- Adds a graphical menu bar status item with workspace/window status, settings
  shortcuts, layout reapply, and safe quit.
- Hot-reloads config changes without restarting, keeping the previous config if
  a saved file cannot be parsed.
- Persists workspace, column order, manual widths, and focused window across
  restarts.
- Parks off-workspace windows near the side edge, with optional SkyLight alpha
  hiding when those private symbols are available.
- Restores tiled windows on normal exit and starts a small cleanup watcher for
  crash or kill recovery.

## Shortcuts

| Shortcut | Action |
| :------- | :----- |
| `Cmd+1`..`Cmd+9` | Focus workspace by dynamic index |
| `Cmd+0` | Focus the previous workspace |
| `Cmd+J` / `Cmd+K` | Focus workspace down / up |
| `Cmd+H` / `Cmd+L` | Focus column left / right |
| `Cmd+[` / `Cmd+]` | Focus first / last column |
| `Cmd+Home` / `Cmd+End` | Focus first / last column |
| `Cmd+Shift+1`..`Cmd+Shift+9` | Move column to workspace |
| `Cmd+Shift+J` / `Cmd+Shift+K` | Move column workspace down / up |
| `Cmd+Shift+H` / `Cmd+Shift+L` | Move column left / right |
| `Cmd+Shift+[` / `Cmd+Shift+]` | Move column to first / last |
| `Cmd+Ctrl+H` / `Cmd+Ctrl+L` | Cycle active column width preset |
| `Cmd+Ctrl+-` / `Cmd+Ctrl+=` | Nudge active column width |
| `Cmd+Ctrl+Shift+H` / `Cmd+Ctrl+Shift+L` | Cycle every tiled window width preset |
| `Cmd+Ctrl+Shift+-` / `Cmd+Ctrl+Shift+=` | Nudge every tiled window width |
| three-finger trackpad swipe | Navigate columns / workspaces |

Everything else passes through. The default config excludes `Cmd+Shift+5`, so
macOS screen recording keeps working.

Trackpad navigation uses Apple's private MultitouchSupport framework so Miri can
see raw three-finger movement without stealing normal two-finger scrolling. It
moves a continuous camera with momentum, then focuses the workspace and column
nearest the camera when the motion settles.

## Config

miri loads the first config file it can read:

- `MIRI_CONFIG`
- `./miri.config.json`
- `$XDG_CONFIG_HOME/miri/config.json`
- `~/.config/miri/config.json`

`$XDG_CONFIG_HOME/miri/config.json` is checked only when `XDG_CONFIG_HOME` is
set. If it is unset, miri falls back to `~/.config/miri/config.json`.

The loaded config file is watched for changes. Saving valid JSON reloads
keybindings, rules, layout settings, animations, and trackpad settings in place.
If a save cannot be parsed, miri keeps running with the previous config.
The menu bar item can open or reveal the loaded settings file, reveal the saved
layout state file, reload settings, reapply the layout, and quit while restoring
tiled windows.

The repo includes a full default config. A compact version looks like this:

```json
{
  "default_width_ratio": 0.8,
  "preset_width_ratios": [0.5, 0.67, 0.8, 1.0],
  "animation_duration_ms": 240,
  "keyboard_animation_ms": 240,
  "hover_focus_animation_ms": 240,
  "trackpad_settle_animation_ms": 240,
  "move_column_animation_ms": 240,
  "width_animation_ms": 280,
  "animation_curve": "smooth",
  "hover_to_focus": true,
  "hover_focus_delay_ms": 120,
  "hover_focus_max_scroll_ratio": 0.15,
  "hover_focus_requires_visible_ratio": 0.15,
  "hover_focus_edge_trigger_width": 8,
  "hover_focus_after_trackpad_ms": 280,
  "hover_focus_mode": "edge_or_visible",
  "workspace_auto_back_and_forth": true,
  "center_focused_column": true,
  "focus_alignment": "smart",
  "new_window_position": "after_active",
  "inner_gap": 0,
  "outer_gap": 0,
  "parked_sliver_width": 1,
  "excluded_keybindings": ["cmd+shift+5"],
  "keybindings": {
    "column_left": ["cmd+h"],
    "column_right": ["cmd+l"],
    "workspace_down": ["cmd+j"],
    "workspace_up": ["cmd+k"],
    "move_column_to_workspace_5": ["cmd+ctrl+shift+5"]
  },
  "trackpad_navigation": true,
  "trackpad_navigation_fingers": 3,
  "trackpad_navigation_sensitivity": 1.6,
  "trackpad_navigation_deceleration": 5.5,
  "trackpad_navigation_hover_suppression_ms": 280,
  "trackpad_navigation_momentum_min_velocity": 80,
  "trackpad_navigation_velocity_gain": 1.35,
  "trackpad_navigation_settle_animation_ms": 240,
  "trackpad_navigation_snap": "nearest_column",
  "trackpad_navigation_invert_x": false,
  "trackpad_navigation_invert_y": false,
  "rescan_interval_ms": 1000,
  "restore_on_exit": true,
  "persist_layout": true,
  "state_path": null,
  "hide_method": "skylight_alpha",
  "debug_logging": false,
  "rules": [
    {
      "bundle_id": "com.apple.finder",
      "behavior": "float"
    }
  ]
}
```

`keybindings` is merged with the built-in defaults by action name, so a config
can override only the actions it cares about. Set an action to `[]` to disable
it. `excluded_keybindings` always wins, so the default `Cmd+Shift+5`
screen-recording shortcut passes through; moving a column to workspace 5 uses
`Cmd+Ctrl+Shift+5`. See `miri.config.json` for the full command-name list.

Keybinding strings support the standard modifiers `cmd`/`win`/`super`, `ctrl`,
`shift`, `alt`/`option`, and `fn`/`globe`. This makes MacBook keyboard shortcuts
like `cmd+fn+left` configurable without requiring a separate Home/End key.

Useful string settings:

- `animation_curve`: `smooth`, `snappy`, or `linear`
- `hover_focus_mode`: `off`, `visible_only`, or `edge_or_visible`
- `focus_alignment`: `left`, `center`, or `smart`
- `new_window_position` and rule `open_position`: `before_active`,
  `after_active`, or `end`
- `trackpad_navigation_snap`: `nearest_column`, `nearest_visible`, or `none`
- `hide_method`: `skylight_alpha` or `park_only`

Rules can match on `bundle_id`, `app_name`, or `title_contains`. Use
`behavior: "ignore"` for windows miri should leave alone, `behavior: "float"`
for visible untiled windows that should be raised above tiled columns, and
`width_ratio` to override an app's default column width. Rules can also set `workspace`, `open_position`,
`trackpad_navigation`, and `hover_to_focus` for matching windows.

With `persist_layout` enabled, miri writes a local layout snapshot to
`$XDG_STATE_HOME/miri/layout.json` or `~/.local/state/miri/layout.json`. Set
`state_path` to override that location. The snapshot uses app names, bundle IDs,
and window titles to match windows after restart.

## Development

```bash
swift build
swift run miri
```

## Releases

Release artifacts are built by `.github/workflows/release.yml`.

- Push a stable tag like `v0.1.0` to publish a GitHub Release.
- Run the workflow manually with `channel: nightly` to publish a prerelease.
- The scheduled nightly checks whether `main` changed since the last nightly tag
  before publishing.
- The macOS artifact is a `Miri-<version>-arm64-darwin.dmg` containing
  `Miri.app`.

## Notes

- miri targets macOS 13+ and Swift 6.
- It uses public Accessibility APIs for the core window control path.
- The SkyLight path is private and optional; if it is unavailable, hidden
  windows stay parked as side-edge slivers.
- This does not use native macOS Spaces.

## Links

- Repository: https://github.com/maria-rcks/miri
- Research notes: [docs/macos-window-management-investigation.md](docs/macos-window-management-investigation.md)
- Niri behavior notes: [docs/niri-mvp-behavior-notes.md](docs/niri-mvp-behavior-notes.md)

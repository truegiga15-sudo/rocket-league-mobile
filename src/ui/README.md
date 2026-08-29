# src/ui — HUD, Menus, Touch Layout

**Owner:** WS76 Main Menu (lead), WS77 HUD, WS78 Touch Layout, WS79 Pause/Settings, WS80 Post-Match, WS81 Loading, WS82 Onboarding, WS84 Localization, WS85 Accessibility
**Branches:** `ws76-*`…`ws85-*`

## Contents
- `main_menu.tscn` — entry scene (`project.godot` run/main_scene)
- `hud/` — scoreboard, timer, boost meter (WS77)
- `touch/` — joystick, button cluster, safe area (WS78)
- `theme.tres` — design tokens, no hardcoded colors
- `menus/` — pause, settings, garage (WS79, WS52)

## Rules
- View-model separation. HUD is overlay, not world-space.
- All text via localization keys (WS84).
- Touch targets ≥48 dp, 56 dp for boost/jump/drift, 8 dp gap.

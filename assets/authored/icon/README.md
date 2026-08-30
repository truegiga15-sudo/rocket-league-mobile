# assets/authored/icon — WS94 Icon

**Owner:** WS94 Icon, Splash, Permissions & Manifest
**Source:** Authored — original Rocket League Mobile icon, not ripped.
**License:** Original work, CC0-equivalent for repo use.
**Naming:** `app_icon_rocket_a_v01.png` follows `category_name_variant_author_v01.ext` (WS03).

## Files
- `app_icon_rocket_a_v01.png` — 512x512 launcher icon (also copied to `assets/icon.png` for Godot `config/icon` source of truth)
- `assets/icon.png` — project.godot `config/icon` = `res://assets/icon.png` (512x512, power-of-two, LFS-tracked via *.png)
- `assets/splash.png` — 1024x512 boot splash (power-of-two, landscape), `boot_splash/image` + `config/splash` in project.godot, bg_color `Color(0.05,0.05,0.08,1)`

Export presets (`export_presets.cfg`) reference `launcher_icons/main_192x192` & `adaptive_foreground_432x432` = `res://assets/icon.png`, permissions minimal `VIBRATE` only.

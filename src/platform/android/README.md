# src/platform/android — Android Lifecycle

**Owner:** WS88 Suspend/Resume (lead), WS93 Build Pipeline, WS94 Icon/Splash/Manifest, WS28 Haptics
**Branches:** `ws88-*`, `ws93-*`, `ws94-*`, `ws28-*`

## Contents
- `lifecycle.gd` — suspend/resume, must not lose match state
- `haptics.gd` — haptics via `InputService` touch cluster
- `export_presets.cfg` fragments, `AndroidManifest` overlays

## Rules
- Landscape locked; portrait shows rotate prompt.
- minSdk 24, Gradle via Godot export, AAB+APK, signing via CI secrets.
- Safe area insets respected.

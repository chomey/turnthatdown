# TurnThatDown Feature Expansion Design

## Current State
- Menu bar popover with system output/input device selection, volume, mute
- Per-app volume control via CATapDescription process taps
- Per-app mute toggle
- Working on macOS 26 with stable code signing

## Feature Plan (Priority Order)

### Phase 1: Polish & Quick Wins
1. **Volume boost up to 200%** — Extend per-app slider range beyond 100% (gain > 1.0 in IOBlock)
2. **Remove debug logging from IOBlock** — Clean up ttdLog calls in hot path
3. **VU meter per app** — Show peak level indicator next to each app's volume slider
4. **Restore mutedWhenTapped** — Already set, verify Spotify goes silent on normal output and only plays through our IOBlock
5. **UI improvements** — Better spacing, scroll behavior, app icon sorting

### Phase 2: Core Features
6. **Per-app output device routing** — Let users route individual apps to different output devices by changing the aggregate device's output sub-device
7. **Global keyboard shortcuts** — Media key intercept for controlling focused app volume, or custom hotkeys
8. **Persistent volume settings** — Remember per-app volume/mute across app restarts using UserDefaults keyed by bundle ID

### Phase 3: Advanced (Stretch)
9. **Auto-pause/resume** — Detect when a new audio source starts, auto-duck or pause music apps
10. **Per-app EQ** — 3-5 band EQ processed in the IOBlock

## Architecture Notes

### Volume Boost
The IOBlock already multiplies samples by `volume`. Allowing values > 1.0 (up to 2.0 for +6dB) with soft limiting to prevent clipping:
```
output = clamp(input * volume, -1.0, 1.0)
```

### VU Meter
Track peak level in the IOBlock (already computed for debug logging), expose via `TappedApp.audioLevel` published property. Display as a thin colored bar under each app's volume slider.

### Per-App Output Routing
Each app's aggregate device already has an output sub-device. To route to a different device:
1. Tear down existing tap + aggregate
2. Recreate with different output device UID in aggregate config
3. Expose device picker per app in UI

### Persistent Settings
Store in UserDefaults:
```json
{
  "com.spotify.client": { "volume": 0.75, "muted": false },
  "com.apple.Music": { "volume": 1.0, "muted": true }
}
```
Apply saved settings when a new tap is created for a known bundle ID.

### Global Hotkeys
Use `NSEvent.addGlobalMonitorForEvents` for media keys or register custom hotkeys with `MASShortcut` or Carbon `RegisterEventHotKey`.

## Out of Scope
- Multi-device simultaneous output (complex aggregate device management)
- Audio Unit plugin hosting
- AirPlay routing
- DDC monitor control
- URL scheme automation

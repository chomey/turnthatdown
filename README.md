# TurnThatDown

Free, open-source per-app volume control for macOS.

![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Per-app volume control** — independent volume sliders for every app playing audio
- **Per-app 5-band EQ** — Bass, Low, Mid, High, Air bands with ±24dB range
- **Per-app L/R balance** — stereo panning per app
- **System volume & device switching** — output/input device picker with volume and mute
- **Global hotkeys** — works even when other apps are focused
  - `Option+Shift+Up/Down` — adjust focused app volume
  - `Option+Shift+M` — mute/unmute focused app
  - `Ctrl+Option+Up/Down` — adjust system volume
  - `Ctrl+Option+M` — mute/unmute system
- **Typeable volume** — click the percentage to type an exact value
- **Hide apps** — right-click to hide apps you don't want to see
- **Launch at Login** — right-click the menu bar icon
- **Scroll wheel** — scroll on menu bar icon to adjust system volume
- **Sorted by loudest** — currently playing apps appear first

## Install

1. Download `TurnThatDown.dmg` from [Releases](https://github.com/chomey/turnthatdown/releases)
2. Open the DMG and drag TurnThatDown to Applications
3. Launch and grant permissions when prompted:
   - **Screen & System Audio Recording** — required to tap app audio
   - **Accessibility** — required for global hotkeys

## Build from Source

```bash
git clone https://github.com/chomey/turnthatdown.git
cd turnthatdown
xcodebuild -scheme TurnThatDown -configuration Release -derivedDataPath build build
open build/Build/Products/Release/TurnThatDown.app
```

## How It Works

TurnThatDown uses Apple's `CATapDescription` API (macOS 14.2+) to create process-specific audio taps. Each tapped app's audio is routed through an aggregate device where the IOBlock callback applies volume scaling, balance panning, and EQ processing before sending it to the output device.

The EQ uses biquad filters (transposed direct form II) with low/high shelf and peaking bands.

## License

MIT

# DoublEnder
### Minimal macOS Audio Recorder

<p align="center">
  <strong>Dead-simple guest recording for podcasters</strong>
  <br />
  <strong>Version:</strong> 1.2.0
  <br />
  <a href="https://github.com/sevmorris/DoublEnder/releases/latest/download/DoublEnder-v1.3.1.dmg"><strong>Download Latest (DMG)</strong></a>
  ·
  <a href="https://sevmorris.github.io/DoublEnder/">App Page</a>
</p>

Pick your microphone, hit the button, get an AAC file on your Desktop. That's it.

<p align="center">
  <img src="docs/images/doublender-idle.png" width="49%" alt="DoublEnder — idle" />
  <img src="docs/images/doublender-recording.png" width="49%" alt="DoublEnder — recording" />
</p>

Designed for podcast guests who shouldn't need to know anything about audio. No setup, no account, no cloud. You send them the app; they record their side of the conversation and send you the file.

---

## Features

- **One-button recording** to AAC (M4A), 256 kbps mono at the input's native sample rate
- **Input selector** — pick any system audio input from the mic dropdown
- **Segmented LED level meter** — 40 segments with green / yellow / orange / red zones and a CLIP indicator
- **Lookahead limiter** — −1 dBFS ceiling on the recorded signal
- **LCD-style timer** — seven-segment HH:MM:SS readout with visible ghost segments
- **Native notifications** — when a recording finishes, a system notification appears with a Reveal in Finder action

**Output:** `DoublEnder_<timestamp>.m4a` saved to the Desktop

---

## Operational Specifications

- **Environment:** macOS 14.0+ (Sonoma); Apple Silicon and Intel
- **Output Format:** AAC/M4A, 256 kbps, mono
- **Dependencies:** None — fully self-contained

## Build

Open `DoubleEnder.xcodeproj` in Xcode and build the `DoubleEnder` scheme, or:

```bash
xcodebuild -project DoubleEnder.xcodeproj -scheme DoubleEnder -configuration Release
```

The project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — if you edit `project.yml`, run `xcodegen generate` to regenerate the Xcode project.

---

### Support
Free forever.

### License
Copyright © 2026 Seven Morris.
Distributed under the [MIT License](LICENSE).

Bundled font: [DSEG7 Classic](https://github.com/keshikan/DSEG) by keshikan, licensed under the SIL Open Font License 1.1.

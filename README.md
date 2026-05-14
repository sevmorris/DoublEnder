# DoublEnder

A minimal macOS audio recorder. Pick an input, hit record, get an AAC/M4A file on your Desktop.

**[→ Download / share page](https://sevmorris.github.io/DoublEnder/)**

**Version:** 1.0.0
**Requires:** macOS 14+

## Features

- Single-button recording to AAC (M4A), 256 kbps mono at the input's native sample rate
- Live RMS + peak metering with clip indicator
- Lookahead limiter (-1 dBFS ceiling) on the recorded signal
- Pick any system audio input from the mic dropdown

## Build

Open `DoubleEnder.xcodeproj` in Xcode and build the `DoubleEnder` scheme, or:

```bash
xcodebuild -project DoubleEnder.xcodeproj -scheme DoubleEnder -configuration Release
```

The project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — if you edit `project.yml`, run `xcodegen generate` to regenerate the Xcode project.

## License

MIT.

Bundled font: [DSEG7 Classic](https://github.com/keshikan/DSEG) by keshikan, licensed under the SIL Open Font License 1.1.

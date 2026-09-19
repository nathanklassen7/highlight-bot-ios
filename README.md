# Highlight Bot iOS

Native iOS app that records continuously into a rolling buffer and, on a trigger, saves the last *n* seconds as a shareable `.mp4` without interrupting recording. Point the phone at the court, leave it running, tap when something happens.

Plan: [docs/ios-app-plan.md](docs/ios-app-plan.md). Interface contracts between modules: [docs/api-contracts.md](docs/api-contracts.md).

## Requirements

- Xcode 26 or later (Swift 6 language mode, strict concurrency).
- iOS 17.2 or later on the device (`AVCaptureEventInteraction` needs 17.2).
- Tested target: iPhone 14 Pro. iPad is allowed but untested.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project.

## Setup

```sh
brew install xcodegen
xcodegen generate
open HighlightBot.xcodeproj
```

In Xcode, select the `HighlightBot` target → Signing & Capabilities → set your Team. `project.yml` leaves `DEVELOPMENT_TEAM` blank on purpose. The `.xcodeproj` is generated; edit `project.yml`, not the project.

## Layout

```
HighlightBot/            App target (SwiftUI + AVFoundation)
  App/                   Entry point, AppContainer (DI), SettingsStore, SwiftData ClipStore
  Capture/               CaptureEngine, SegmentedRecorder, ClipExporter, RecordingPipeline
  Triggers/              TapTrigger, HardwareTrigger
  Features/              Record, Library, Settings screens
  Support/               Permissions, storage/thermal monitors, logging
  Resources/             Asset catalog; drop replay.mov here for the Simulator
HighlightCore/           Swift package: ring buffer, clip assembly, session state machine, trigger bus
docs/                    Plan and API contracts
```

## HighlightCore tests

The package has no UIKit or AVFoundation dependencies and tests on macOS:

```sh
cd HighlightCore && swift test
```

`--disable-sandbox` is only needed when running inside a sandboxed agent shell; normal terminals don't need it. CI runs the same command on every push and pull request (`.github/workflows/core-tests.yml`).

## Running in the Simulator

The Simulator has no camera, so Simulator builds replay a bundled video through the full pipeline instead. Put a landscape video named `replay.mov` in `HighlightBot/Resources/`, run `xcodegen generate`, and build. Without it the app runs but the preview is empty. See `HighlightBot/Resources/README.md`.

## Triggers

| Gesture / input | Idle | Recording |
| --- | --- | --- |
| Tap anywhere on the Record screen | Starts recording | Saves the last *n* seconds |
| Long-press (0.6 s) | Starts recording | Stops recording (also wakes the dimmed screen) |
| Volume button, Camera Control, Bluetooth shutter (e.g. AB Shutter3) | — | Saves the last *n* seconds |
| Record/stop button | Starts | Stops |

*n* is picked on the Record screen (10 / 20 / 30 / 60 s, capped at the buffer length in Settings; default 20 s). Saving never stops recording; several saves can be in flight at once. Recording stops itself after the inactivity timeout (default 45 min) with a warning 5 minutes before.

Clips land in `Documents/Clips/` and are visible in the Files app. Share, Save to Photos, and Delete are in the Library tab and the player.

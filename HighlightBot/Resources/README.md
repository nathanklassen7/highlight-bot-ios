# Resources

`Assets.xcassets` holds the app icon slot (no image yet) and the accent color.

## Simulator replay

The Simulator has no camera. In Simulator builds `AppContainer` swaps
`CaptureEngine` for `FileReplayCaptureSource`, which plays a bundled video
through the same recorder → ring buffer → export pipeline.

To enable it, drop a landscape video named `replay.mov` into this directory,
then run `xcodegen generate` so the file is added to the target. H.264 or HEVC,
1080p, 30 or 60 fps, with an audio track, is the closest match to a real
capture. Without the file the app logs a warning and the Record screen shows
an empty preview.

`replay.mov` is not committed; keep it local.

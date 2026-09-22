# Portrait Video — Design

**Status:** proposed, awaiting review
**Scope of this document:** let the app record, store, show, edit, and montage clips in either orientation. Landscape-only assumptions are removed from capture and UI; the Library shows square thumbnails; the player and editor letterbox or pillarbox any aspect ratio; the montage editor asks which orientation to keep when its clips disagree.

## Summary

Today every clip is landscape because two places force it: `CaptureEngine.landscapeAngle` (`HighlightBot/Capture/CaptureEngine.swift:147`) snaps the rotation coordinator's angle to 0° or 180° before it reaches the writer, and `RootView.applyOrientation` (`HighlightBot/Features/RootView.swift:141`) locks the Record tab to landscape. Everything downstream already tolerates a rotated `preferredTransform` (the player layer uses `resizeAspect`, `ClipTrimmer` carries the transform, `MontageComposition` letterboxes per item), but it was never exercised, and the Library grid hard-codes 16:9 cells.

The plan: **orientation is decided when recording starts and frozen until it stops, exactly like the iOS Camera app.** The sensor keeps delivering native landscape frames and the encoder keeps 1920×1080; the only capture-side change is that 90° and 270° become legal values for the writer's `transform`. `ClipRecord` gains the oriented pixel size so views and the montage prompt can reason about orientation without opening the file. The Library switches to square, center-cropped cells (Photos style). The montage editor stores an `outputOrientation` on the draft and prompts once on save when clips are mixed; `MontageComposition` takes the render size from that choice instead of from the first item.

Encoder settings, ring buffer, segment format, sharing, and Save to Photos need no change: portrait is metadata, not pixels.

## Goals and non-goals

Goals
- Record portrait clips by holding the phone upright. The file plays upright in Photos, Messages, and the app.
- Library thumbnails render as squares regardless of clip orientation.
- Player and editor show the correct black bars for any aspect ratio in any interface orientation.
- Montage with mixed orientations prompts the user to pick the output orientation; the other orientation is fit inside with black bars.
- Existing landscape clips keep working with no migration step the user notices.
- Pure orientation logic (angle snapping, orientation classification, render-size choice) lives in `HighlightCore` and is unit-tested.

Non-goals (this design)
- Rotating a recording mid-session. Orientation freezes at record start (see Decision 1).
- Cropping instead of letterboxing in the montage (a "fill" option). Letterbox only.
- Square or custom output aspect ratios for the montage.
- An orientation filter or badge in the Library.
- Re-generating thumbnails for existing clips (the old 640×360 JPEGs crop fine into a square).

## User flow

1. Record tab now rotates with the phone while idle. Hold it upright, tap to start: the UI locks to portrait and the preview stops following the horizon. Rotate the phone during recording and the preview appears sideways, which is what the clip will look like. Stop: the UI and preview follow the phone again.
2. Every clip saved in that session is stamped portrait (transform 90° or 270°). Library shows it in a square cell, center-cropped like every other cell.
3. Tap it: the player fills the screen in portrait, pillarboxes in landscape. Swipe to a landscape neighbour: it letterboxes. Poster thumbnails match the video framing during the swap, as today.
4. Trim/edit: the preview letterboxes or pillarboxes inside the space between the top bar and controls. Save keeps the orientation whether or not slow-mo is involved.
5. Montage of two landscape clips and one portrait clip: the footer carries a setting reading **Keep Landscape · 1 clip letterboxed**, defaulted to the orientation with more total seconds. Tapping it offers **Keep Landscape (1 clip gets black bars)** and **Keep Portrait (2 clips get black bars)**. Choosing only updates the setting — nothing is encoded, exactly like a trim. The check mark is still the only thing that exports, and it never interrupts with a question.
6. Montage where every clip shares an orientation: no prompt; output matches.

## Key decisions

### 1. Orientation freezes at record start (Camera app behaviour)

`SegmentedRecorder` sets `AVAssetWriterInput.transform` once, before `startWriting()` (`SegmentedRecorder.swift:136`), and the ring buffer shares one initialization segment per session. A rotation mid-recording cannot be written into the running session.

Options considered:
- **Freeze at start (chosen).** `RecordingPipeline.startRecording` already reads `source.captureRotationAngle` once (`RecordingPipeline.swift:218`). Add: lock the interface orientation to the current one while `sessionState.isRecording`, and stop updating the preview connection's rotation while recording. What you see is what the file gets. This is what iOS Camera does.
- Restart the writer session on rotation (as `restartSession()` does after an interruption). Correct files, but the ring buffer evicts the previous session, so the user silently loses their buffer at the moment they rotate. On a tripod that never happens; handheld it happens by accident. Rejected: a silent buffer loss is worse than a visibly sideways preview.
- Rotate pixels per frame by setting `videoRotationAngle = 90` on the data output connection. Changes the encoder dimensions to 1080×1920, which breaks `RecordingConfig.width/height`, format selection, and the 120 fps/720p rule. Rejected.

Snapping: replace `landscapeAngle(_:last:)` with a pure `CaptureRotation.snapped(_:)` in `HighlightCore` that rounds to the nearest of 0/90/180/270. The rotation coordinator already reports those four values; the helper is for safety and testability. The `last:` parameter and its "keep the previous landscape heading" rule go away, because 90/270 are now valid answers rather than ambiguous ones.

Upside-down: `UISupportedInterfaceOrientations` excludes portrait-upside-down on iPhone, so the UI never rotates there, but `videoRotationAngleForHorizonLevelCapture` still reports 270° for a phone held that way. The clip comes out upright anyway. No special case.

### 2. Portrait is metadata; the encoder path does not change

`config.width/height` stay sensor-native (1920×1080 or 1280×720). `SegmentedRecorder.videoSettings` is untouched. The Settings "Resolution" picker keeps saying 1080p. `AVAssetExportSession` passthrough (`ClipExporter.export`) preserves the track transform, so the saved `.mp4` has `naturalSize` 1920×1080 and `preferredTransform` rotated 90°. Every consumer that already calls `appliesPreferredTrackTransform = true` or uses `resizeAspect` renders it correctly.

### 3. `ClipRecord` gains `videoWidth`/`videoHeight` (oriented)

Views and the montage prompt need to know a clip's orientation without opening the file on the main actor. Add two `Int` fields, post-transform (a portrait 1080p clip stores 1080×1920), with default `0`, mirroring how `tags`/`isStarred`/`isMontage` were added:

- `ClipRecord.videoWidth`, `videoHeight` (`Int`, default 0, `decodeIfPresent`). They are capture fields, so `with(...)` does not take them. A new `ClipRecord.orientation: ClipOrientation` computed property classifies `.landscape`, `.portrait`, `.square`, or `.unknown` (either side 0).
- `Clip.videoWidth: Int = 0`, `videoHeight: Int = 0` in SwiftData; lightweight migration adds the columns.
- `ClipStore.replaceMedia` copies the new values from `ExportedClip`.

Legacy records: every clip written before this change is landscape by construction, so `.unknown` is treated as landscape wherever a decision is needed (`ClipOrientation.effective` → `.landscape`). No backfill pass. The montage compositor reads the true size from the asset anyway (it already loads `naturalSize` and `preferredTransform`), so the record's numbers only steer UI and the prompt.

`ExportedClip` gains `videoWidth`/`videoHeight`, filled by a shared helper `ClipExporter.orientedSize(of: AVAsset)` that applies `preferredTransform` to `naturalSize`. `ClipExporter.export`, `ClipTrimmer.trim`, and `MontageExporter.export` all already load the output asset for duration or the thumbnail; the size read piggybacks on that.

### 4. Thumbnails: one full-frame JPEG, square crop in the view

`ClipExporter.writeThumbnail` uses `maximumSize = 640×360` (`ClipExporter.swift:235`). With the transform applied, a portrait frame fits that box at 203×360, too small for a square cell. Change the bound to **960×960** so the long edge is 960 for either orientation (landscape → 960×540, portrait → 540×960). Roughly double the JPEG bytes (~100 KB), negligible beside a 25 MB clip.

The file stays full-frame and uncropped. `ClipPlayerScreen.pageThumbnail` relies on the poster matching the player's `resizeAspect` framing so a landed page and the video that replaces it line up (`ClipPlayerScreen.swift:548`); a pre-cropped square would break that. Squaring happens in `ClipCell` with `ThumbnailImage(contentMode: .fill)` inside a `1:1` frame, which is what the view already does for 16:9.

All three exporters call the one `writeThumbnail`, so this is a single change.

### 5. Library grid: square, center-cropped cells

`ClipCell` changes `.aspectRatio(16 / 9, contentMode: .fit)` (`LibraryScreen.swift:684`) to `.aspectRatio(1, contentMode: .fit)`. Landscape thumbnails lose their sides, portrait ones lose top and bottom; that is the Photos app convention and what "render as squares" asks for. The alternative, letterboxing the thumbnail inside the square, wastes a third of every cell on black and is not proposed.

Square cells at the current `GridItem(.adaptive(minimum: 160))` give two columns on an iPhone, each row ~200 pt tall, so about three rows fit on screen. Propose `minimum: 110` for three columns on iPhone portrait, five or six on iPad. The duration badge (`caption2`), single tag pill, and selection check still fit at 110 pt. See Assumptions.

`LibraryDragSelectBridge` hit-tests real cell frames via `ClipHitAnchorView`, so cell shape does not affect drag-select.

Other fixed 16:9 thumbnails become squares for consistency: `RecordScreen.lastClipButton` (`96×54` → `64×64`) and `MontageRow` (`96×54` → `56×56`).

### 6. Player and editor: already correct, now verified

`PlayerUIView` sets `videoGravity = .resizeAspect` (`PlayerLayerView.swift:42`) and `AVPlayerLayer` honours `preferredTransform`, so a portrait clip pillarboxes in a landscape window and fills a portrait one. The poster and neighbour pages use `ThumbnailImage(contentMode: .fit)`. The editor's filmstrip loads frames with `appliesPreferredTrackTransform = true` into a 240×240 box and displays them `scaledToFill`, which works for either orientation. `ClipTrimmer.composition` copies `preferredTransform` onto the composition track; the passthrough trim keeps it via `timeRange` on the source asset.

No code change is planned for these screens beyond the device checklist. If the checklist finds a mismatch (for example the editor's `PlayerLayerView` not clipping in compact height), fix it there.

### 7. Montage: `outputOrientation` on the draft, render size from the choice

`MontageComposition.build` lets the first item decide the render size (`MontageComposition.swift:61-72`). Replace with an explicit `renderSize` parameter chosen by a pure function in `HighlightCore`:

```swift
public enum ClipOrientation: String, Sendable, Codable { case landscape, portrait, square, unknown }

public enum MontageFraming {
    /// Orientations present among the items, ignoring `.unknown` (legacy → landscape).
    public static func orientations(of items: [MontageItem]) -> Set<ClipOrientation>
    /// True when the user must be asked which orientation to keep.
    public static func needsChoice(_ items: [MontageItem]) -> Bool
    /// The orientation with the most output seconds; listed first in the prompt.
    public static func suggestedOrientation(for items: [MontageItem]) -> ClipOrientation
    /// Largest oriented size among items of `orientation`; falls back to 1920×1080 / 1080×1920.
    public static func renderSize(for items: [MontageItem], keeping orientation: ClipOrientation) -> (width: Int, height: Int)
    /// Items that will get black bars under `orientation`.
    public static func letterboxedCount(_ items: [MontageItem], keeping orientation: ClipOrientation) -> Int
}
```

`MontageDraft` gains `public var outputOrientation: ClipOrientation?` and `resolvedOrientation` (the explicit choice, else the single shared orientation, else the suggestion). `MontageEditorScreen` shows the resolved orientation and letterboxed count in the footer whenever `MontageFraming.needsChoice(draft.items)` is true, as a capsule setting beside the clip count. Tapping it opens a `confirmationDialog` listing both orientations (suggested first), each labelled with how many clips get black bars; choosing sets `draft.outputOrientation` and returns. The check mark always exports with `draft.resolvedOrientation` and never prompts: the orientation is a draft setting like a trim, not a step in saving.

`MontageComposition.build(_ items:, renderSize:)` uses the passed size for `videoComposition.renderSize` and for `fitTransform`, and prices `ExportWorkload.pixelCount` from it. `fitTransform` is unchanged: it already scales and centres any oriented source into any frame. Side effect worth having: mixed 720p and 1080p sources of the same orientation now render at 1080p instead of whichever came first.

`MontageExporter` stamps the montage's `videoWidth/videoHeight` from the render size.

### 8. Interface orientation

`RootView.applyOrientation`:
- Record tab, not recording: `.allButUpsideDown` (was `.landscape`, forced).
- Any tab while recording: the current interface orientation only, read from the window scene. Recording already forces the Record tab, so this is the lock from Decision 1.
- Library/Settings: `.allButUpsideDown`, unchanged.

`InterfaceOrientationLock.apply` keeps its signature; `RootView` computes the mask.

### 9. Record screen layout in portrait

`controlsOverlay` was written for landscape but stays mounted in portrait (see the comment at `RecordScreen.swift:123`), and `ViewThatFits` already picks `bottomControlsCompact` when the wide row does not fit. Expect small fixes, not a redesign: the top row (status pill, save badge, lens, dim) may wrap at 390 pt with the debug overlay on; the clip-seconds picker (four capsules) and the tags button are already stacked in the compact layout. The device checklist covers 4.7", 6.1", and iPad portrait.

### 10. Simulator replay reads the file's orientation

`FileReplayCaptureSource.captureRotationAngle` returns 0 (`FileReplayCaptureSource.swift:170`). `AVAssetReader` delivers frames in stored orientation and drops the transform, so a portrait `replay.mov` currently records as sideways landscape. Read the track's `preferredTransform` in `start()` and return its rotation angle, so a portrait replay file exercises the whole portrait path in the Simulator. Update `HighlightBot/Resources/README.md` and the `AppContainer` warning string, which say "landscape".

## Data flow

```
RotationCoordinator ─▶ CaptureEngine.rotation (snapped 0/90/180/270; frozen while recording)
        │                       │
        ▼                       ▼
 preview connection      RecordingPipeline.startRecording ─▶ SegmentedRecorder(videoRotationAngle:)
 (frozen while recording)                                          └─▶ AVAssetWriterInput.transform
                                                                             │
ClipExporter.export ── passthrough keeps transform ──▶ .mp4 + 960-box thumbnail + orientedSize
        │
        ▼
ClipRecord(videoWidth, videoHeight) ─▶ Clip (SwiftData) ─▶ ClipCell (1:1, .fill) / ClipPlayerScreen (.resizeAspect)
        │
        ▼
MontageDraft(items, outputOrientation?) ─▶ MontageFraming.renderSize ─▶ MontageComposition.build(items, renderSize:)
```

## Repercussions checked

- **Ring buffer / segments.** Untouched; the transform lives in the init segment's track header. A session is single-orientation by Decision 1.
- **Save to Photos / Share.** Rotated `preferredTransform` is the standard iOS representation; Photos, Messages, and QuickTime all honour it. Verify once on device.
- **Trim passthrough.** `AVAssetExportSession` without a `videoComposition` preserves the transform. Verify with `AVAssetExportPresetHighestQuality` and `HEVCHighestQuality`; if either strips it, `ClipTrimmer` routes every trim through `composition(of:…)`, which sets it explicitly.
- **Export time estimate.** `ExportWorkload.pixelCount` follows the render size; no change to the estimator.
- **Thermal frame-rate changes.** Orientation-independent.
- **Voice / hardware triggers.** Orientation-independent. `AVCaptureEventInteraction` fires regardless of interface orientation.
- **Debug overlay.** Add one line, `rotation   90°`, from a new `PipelineMetrics.rotationDegrees` so a sideways clip can be diagnosed from the overlay.
- **Ball tracking (docs only, not yet built).** `docs/superpowers/specs/2026-09-18-ball-tracking-design.md:79` says clips carry 0° or 180°. `FrameOrientation` there is already specified for 0/90/180/270; update the sentence so the plan does not skip the portrait cases.
- **Docs.** `docs/api-contracts.md:17` ("landscape only") and `:612` (orientation plist keys), `docs/ios-app-plan.md:149` and the §6 table: update to "either orientation; frozen per recording session".
- **Dimmed mode.** `DimmedModeView` is a full-screen black overlay; unaffected by orientation lock.
- **Existing thumbnails.** 640×360 JPEGs crop into squares at 360 px on a side, softer than new ones on a 3× screen at 110 pt (330 px). Acceptable; regeneration is a follow-up if it bothers anyone.

## Error handling

- `captureRotationAngle` unavailable (no rotation coordinator yet): defaults to 0 as today; the clip is landscape.
- A clip with `videoWidth == 0` in the montage is classified landscape for the prompt. If the file turns out portrait, the compositor still renders it correctly (it reads the asset); only the prompt's count could be off by one for a legacy record, which cannot happen because legacy records are landscape.
- Montage export failure or cancel: `outputOrientation` stays on the draft, so retry skips the dialog.
- Interface lock during recording is best-effort (`requestGeometryUpdate` may fail on some iPads); the file orientation does not depend on it.

## Testing

`HighlightCoreTests`
- `CaptureRotationTests`: snapping of -10, 44, 45, 89, 91, 269, 315, 359, 450 to 0/90/180/270.
- `ClipOrientationTests`: classification from width/height including 0 and square; `effective` maps unknown → landscape.
- `MontageFramingTests`: `needsChoice` for all-landscape, all-portrait, mixed, mixed-with-unknown; `suggestedOrientation` by output seconds (trim and slow-mo included); `renderSize` picks the largest of the kept orientation and falls back correctly; `letterboxedCount`.
- `ClipRecord` Codable: round trip with sizes; legacy JSON decodes to 0/0.
- `MontageDraftTests`: `outputOrientation` defaults nil, survives `move` and `update`, `resolvedOrientation` rules.

App: Simulator build per task. Add a portrait `replay.mov` locally to exercise capture in the Simulator (Decision 10).

Device checklist (final task)
1. Record portrait; rotate to landscape mid-recording; confirm the preview goes sideways and the UI does not rotate; stop; confirm the UI rotates again. The saved clip plays upright in Photos.
2. Record landscape, then portrait, in two sessions. Library shows both as squares; long-press Trim on each; Save as New keeps orientation; Replace Original keeps orientation; slow-mo and replay variants keep orientation.
3. Player: portrait clip in portrait (full screen) and landscape (pillarbox); swipe between a portrait and a landscape clip; the poster never jumps.
4. Montage: 2 landscape + 1 portrait → the footer setting defaults to landscape; changing it encodes nothing and the check mark is still required; export once per orientation and play both results in Photos; cancel an export and retry with the setting unchanged.
5. Montage: all-portrait → no dialog, portrait output. All-landscape with a 720p first clip and a 1080p second → output is 1080p.
6. Record screen in portrait on the smallest supported iPhone: every control reachable with the debug overlay on and off.
7. Upside-down phone (iPhone): UI stays put, the clip is upright.

## Implementation plan

Ordered so each step builds and ships on its own. Waves 1 and 2 are independent of each other; 3 needs 2; 4 and 5 need 3; 6 needs 4.

| # | Task | Files | Verify |
| --- | --- | --- | --- |
| 1 | `CaptureRotation.snapped`, `ClipOrientation`, `MontageFraming` in Core with tests | `HighlightCore/Sources/HighlightCore/Clips/ClipOrientation.swift`, `…/Clips/MontageFraming.swift`, `…/Config/CaptureRotation.swift`, tests | `swift test` |
| 2 | `ClipRecord.videoWidth/videoHeight` + `orientation`; `Clip` columns; `ExportedClip` fields; `ClipExporter.orientedSize`; all three exporters fill them; `ClipStore.replaceMedia` copies them; thumbnail box 960×960 | `ClipRecord.swift`, `Clip.swift`, `ClipExporter.swift`, `ClipTrimmer.swift`, `MontageExporter.swift`, `ClipStore.swift`, `RecordingPipeline.saveClip` | Core tests; app build; record a clip and read the size in the debug log |
| 3 | Capture: replace `landscapeAngle` with `CaptureRotation.snapped`; freeze preview rotation while recording (pipeline tells the source via a new `setRotationFrozen(_:)` on `CaptureSource`, no-op in replay); `RootView` orientation masks; `PipelineMetrics.rotationDegrees` + overlay line; replay source reads `preferredTransform`; README/warning text | `CaptureEngine.swift`, `CaptureSource.swift`, `FileReplayCaptureSource.swift`, `RecordingPipeline.swift`, `RootView.swift`, `DebugOverlay.swift`, `Resources/README.md`, `AppContainer.swift` | Device: portrait clip upright in Photos; Simulator with portrait `replay.mov` |
| 4 | Record screen portrait layout pass; square `lastClipButton` | `RecordScreen.swift` | Simulator iPhone SE/15/iPad portrait |
| 5 | Library square cells, 3-up columns; `MontageRow` square thumb | `LibraryScreen.swift`, `MontageEditorScreen.swift` | Simulator; drag-select still works |
| 6 | `MontageDraft.outputOrientation`; `MontageComposition.build(_:renderSize:)`; prompt + footer in `MontageEditorScreen`; montage record size | `MontageDraft.swift` (+tests), `MontageComposition.swift`, `MontageExporter.swift`, `MontageEditorScreen.swift` | Core tests; device: mixed montage both ways |
| 7 | Docs: `api-contracts.md`, `ios-app-plan.md`, ball-tracking spec sentence | `docs/` | — |
| 8 | Device checklist above | — | report |

Global constraints carry over from the montage plan: Swift 6 strict concurrency, Core is Foundation-only and tests on macOS, `xcodegen generate` after adding files, one-line imperative commits, verification scratch files under `/tmp`.

## Assumptions to confirm

Each is a one-line change if you want it different.

1. **Orientation freezes at record start** (Camera app behaviour) rather than restarting the buffer on rotation.
2. **Square thumbnails crop** (Photos style) rather than letterbox inside the square.
3. **Three columns on iPhone portrait** (`minimum: 110`) rather than today's two, because square cells are taller.
4. **Chooser copy**: "Keep Landscape / Keep Portrait", each with "(N clips get black bars)". The orientation with more output seconds is listed first and is what an untouched draft resolves to.
5. **The footer setting is hidden when orientations match**, and the choice is remembered on the draft across a failed export.
6. **Legacy clips are landscape**; no backfill of `videoWidth/videoHeight`.
7. **Thumbnail bound 960×960**; existing thumbnails are not regenerated.
8. Interface orientation is locked to whatever the phone is at when recording starts, on every tab, until recording stops.

## Follow-ups (not in this plan)

- "Fill" option in the montage prompt (crop the minority orientation instead of letterboxing).
- Orientation badge or filter pill in the Library.
- Regenerate legacy thumbnails at 960 on first launch after upgrade.
- A Settings toggle to lock recording to landscape for users who never want portrait.
- Ball tracking: `FrameOrientation` for 90/270 when that work starts.

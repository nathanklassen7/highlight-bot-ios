# Montage Editor — Design

**Status:** proposed, awaiting review
**Scope of this document:** a montage builder that joins several Library clips, each with its own trim and slow-mo, into one new clip flagged as a montage.

## Summary

From Library select mode, the user picks two or more clips and taps a new circular trim button (above the tags button). A full-screen **Montage** screen lists the clips oldest first. The user drags rows to reorder and taps a row to open the existing trim/edit screen for that clip. In the montage, the editor's confirm does **not** re-encode: it hands the trim and slow-mo settings back to the montage draft, so the clip can be reopened and tweaked. The check mark on the montage screen renders every clip's edit in order into one new `.mp4`, inserts it into the Library with `createdAt = now` and a new `isMontage` flag stored beside `isStarred`.

The single-clip editor keeps working exactly as it does today; it gains a second mode rather than a fork.

## Goals and non-goals

Goals
- Build a montage from ≥ 2 selected Library clips, reordering by drag.
- Reuse `ClipEditorScreen` for per-clip trim and slow-mo with identical controls.
- Per-clip edits are stored in the draft and re-editable until export.
- One export step writes a new clip: `createdAt = now`, `isMontage = true`, tags shared by every source clip, not starred, `triggerSource = .ui`.
- `isMontage` persisted in SwiftData and `ClipRecord` with the same lightweight-migration pattern as `isStarred`.
- Pure ordering/duration logic lives in `HighlightCore` so it runs under `swift test` on macOS (the app target has no test bundle).

Non-goals (this design)
- Persisting an unfinished montage draft across app launches. The draft lives in the montage screen's state; Cancel discards it (with a confirmation once anything has changed).
- Removing a clip from inside the montage, adding clips, transitions, music, or a title card.
- A Library filter for montages, or a montage badge beyond swapping the trigger icon in the grid cell.
- Editing a finished montage back into its parts. The montage is a normal clip afterwards; it can be trimmed like any other.

## User flow

1. Library → Select → tap ≥ 2 clips. The montage button (scissors, circular, above Tags) enables at 2.
2. Tap it → `MontageEditorScreen` opens full screen. Rows: index, thumbnail, capture date, output length (yellow when edited, tortoise glyph when slow-mo). Order is oldest first.
3. Drag a row's handle to reorder. Tap a row → `ClipEditorScreen` in **configure** mode, seeded with that clip's saved edit. Top-right reads **Done** (always enabled) instead of Save; no Replace/Copy dialog; nothing is encoded. Cancel discards only this visit's changes.
4. Footer shows total output length and clip count. Top-right check mark exports. The screen locks with an "Exporting montage…" overlay (same pattern as the trimmer).
5. On success: haptic, the montage screen dismisses, Library leaves select mode, toast "Montage saved", and the new clip is at the top of the grid (newest first) with a `film.stack` glyph in place of the trigger icon.
6. On failure: error haptic and toast; the draft stays so the user can retry or cancel.

## Key decisions

### 1. Editor gets a mode, not a copy

`ClipEditorScreen` is ~760 lines of playback and gesture handling that took several commits to get right. Duplicating it for the montage would double the bug surface. Instead:

```swift
enum ClipEditorMode {
    case export(onComplete: (ClipEditOutcome) -> Void)   // today's behaviour
    case configure(onDone: (ClipEdit) -> Void)          // montage child
}
```

The only behavioural differences in `configure`: the top-right button is "Done" (always enabled, returns `currentEdit`), the hint text no longer says "Saving re-encodes the clip", and `save(replacingOriginal:)` is unreachable. Everything else (preview, slow-mo replay, filmstrip, VoiceOver) is shared. The existing `init(record:onComplete:)` remains so `ClipPlayerScreen` and `LibraryScreen` don't change.

### 2. `ClipEdit` is the unit of "saved trim and slow-mo config"

A small value type: `start`, `end`, `slowMotion: SlowMotionSegment?`, `isSlowMotionReplay`. It has `outputDuration` (selection plus slow-mo stretch or replay), `hasChanges(clipDuration:)`, and `clamped(toClipDuration:minimumDuration:)` for when the file's true length disagrees with the record. `Codable` so a future "resume draft" feature can persist it without a schema change.

This requires moving `SlowMotionSegment` from `ClipTrimmer.swift` into `HighlightCore` and making it public. It is pure Foundation, so it fits the package's dependency-free rule, and it gains unit tests it never had.

### 3. `MontageDraft` in `HighlightCore` owns order and edits

`MontageDraft(clips:)` sorts oldest first (ties broken by id for a stable order) and wraps each clip as a `MontageItem { clip, edit }`. It exposes `move(fromOffsets:toOffset:)`, `update(_:for:)`, `totalDuration`, `hasChanges`, and `minimumClipCount = 2`. The montage screen holds one as `@State` and never touches ordering logic itself.

### 4. One composition, one video composition

`MontageComposition.build(items)` appends each item to a single video and a single audio composition track at a running cursor, applying slow-mo with `scaleTimeRange` immediately after each insert (before the cursor moves, so later items are never displaced by an earlier scale). This is `ClipTrimmer.composition(of:range:slowMotion:replay:)` generalised to N items.

Orientation is handled with an `AVMutableVideoComposition`: one instruction per item whose layer transform applies the source's `preferredTransform` and letterboxes it into the first item's oriented frame. A single `preferredTransform` on the track (what `ClipTrimmer` does) would render mixed portrait/landscape sources wrong. The export re-encodes anyway, so the video compositor adds no extra pass. Frame duration follows the first item's nominal frame rate; codec preset follows the first item (HEVC stays HEVC) via the same helper `ClipTrimmer` uses.

Rejected: exporting each clip with `ClipTrimmer` then concatenating. Two encodes per clip, and passthrough concatenation of separately encoded files is unreliable.

### 5. `isMontage` mirrors `isStarred` end to end

- `ClipRecord.isMontage: Bool` with default `false` in `init`, `decodeIfPresent` in `init(from:)`, and a parameter on `with(...)`.
- `Clip.isMontage: Bool = false` so SwiftData adds the column to existing stores without a migration plan, exactly as `tags` and `isStarred` did.
- `ClipEditorScreen`'s "Save as New Clip" copies the flag so a trimmed montage stays a montage.
- `ClipCell` shows `film.stack` instead of the trigger icon when set.

### 6. Reorder with `List` + `.onMove` in active edit mode

Drag handles appear on every row and reordering uses UIKit's reorder control, which is reliable and accessible (VoiceOver users get the standard "Reorder" action). Row taps are handled with `onTapGesture` on the row content, which works in edit mode with no selection binding. The alternative, `.draggable`/`.dropDestination` on a `VStack`, allows lifting a row from anywhere but needs custom drop-index logic; it can replace the list later without touching the draft or exporter.

## Data flow

```
LibraryScreen (select mode, ≥2 ids)
  └─ MontageRequest(clips: selectedRecords)           [fullScreenCover]
      └─ MontageEditorScreen  @State draft: MontageDraft
           ├─ List(draft.items).onMove → draft.move
           ├─ row tap → ClipEditorScreen(record:, edit:, onDone:)   [fullScreenCover]
           │                └─ Done → draft.update(edit, for: id)
           └─ check → MontageExporter.export(draft.items, baseName)
                        ├─ MontageComposition.build → (AVMutableComposition, AVMutableVideoComposition)
                        ├─ ClipExporter.runExport(asset:preset:videoComposition:to:)
                        ├─ ClipExporter.writeThumbnail
                        └─ ExportedClip → ClipRecord(isMontage: true) → clipStore.insert
                                          → container.lastClip → onComplete → dismiss
```

## Error handling

- Fewer than 2 items, a missing source file, or an invalid edit (too short, slow-mo outside the range) throws `MontageError` before any AVFoundation work starts; the message names the clip index.
- Export failure: files are not indexed; the toast shows the error; the draft is untouched.
- Insert failure after a successful export: `ClipTrimmer.discard(exported)` removes the orphaned files, then the error surfaces as a toast (same as the trimmer).
- The screen is `interactiveDismissDisabled` and `disabled` while exporting.

## Testing

- `HighlightCoreTests`: `SlowMotionSegment` maths, `ClipEdit` durations and clamping, `MontageDraft` ordering/move/update/totals, `ClipRecord` `isMontage` Codable round trip and legacy decode.
- App: simulator build after every app task (`xcodegen generate` then `xcodebuild … build`). No app unit tests exist.
- Device checklist (final task): mixed landscape/portrait sources, HEVC and H.264 sources, slow-mo in-place and replay in the same montage, reorder then edit then reorder again, cancel with and without changes, export failure path (delete a source file from the Files app mid-draft).

## Assumptions to confirm

These are judgment calls made so the plan is complete; each is a one-line change if you want it different.

1. Montage tags = tags every source clip shares (same rule the bulk tag picker seeds from). Alternative: no tags.
2. Montage is not starred, `triggerSource = .ui`.
3. The montage button needs ≥ 2 selected clips.
4. Editor "Done" is always enabled in configure mode (resetting a clip back to full length is a valid edit).
5. Draft is in-memory only. Cancel asks for confirmation only after a reorder or edit.
6. Mixed frame sizes/orientations letterbox into the first clip's frame.

## Follow-ups (not in this plan)

- Swipe-to-remove a clip from the montage.
- "Montage" filter pill in the Library filter bar.
- Persist drafts (`ClipEdit` and `MontageDraft` are already `Codable`-ready).
- Cross-fade or cut-to-black between items.

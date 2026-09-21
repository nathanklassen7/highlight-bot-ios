# Montage Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user select several Library clips, order them, trim/slow-mo each one with the existing editor, and export the sequence as one new clip flagged `isMontage`.

**Architecture:** Pure value types (`SlowMotionSegment`, `ClipEdit`, `MontageItem`, `MontageDraft`) move into or are added to `HighlightCore` so ordering and duration maths are unit-tested on macOS. `ClipEditorScreen` gains a `configure` mode that returns a `ClipEdit` instead of encoding. A new `Features/Montage/` folder holds `MontageEditorScreen` (list + reorder + export flow), `MontageComposition` (one `AVMutableComposition` + `AVMutableVideoComposition` for N items) and `MontageExporter` (validation, export, thumbnail). `LibraryScreen` adds the select-mode button and cover. `Clip`/`ClipRecord` gain `isMontage` the same way they gained `isStarred`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftData, AVFoundation (`AVMutableComposition`, `AVMutableVideoComposition`, `AVAssetExportSession`), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-21-montage-editor-design.md`

## Global Constraints

- Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete` (`project.yml`, `HighlightCore/Package.swift`).
- `HighlightCore` stays Foundation-only (no AVFoundation, UIKit, or SwiftUI imports) and must build and test on macOS 14.
- `HighlightCore` public API needs `public` on every type, member, and initializer the app uses.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`) as in `HighlightCoreTests`.
- Logging via `Log.export` / `Log.ui` (`OSLog`). No `print`.
- Commit messages: imperative, no prefix, one line, matching repo history ("Add montage draft model to HighlightCore").
- The `.xcodeproj` is generated. After adding or moving any file under `HighlightBot/` or `HighlightCore/`, run `xcodegen generate` before building.
- Core test command (run from `HighlightCore/`): `swift test`. Inside an agent sandbox add `--disable-sandbox`.
- App build command (run from the repo root): `xcodebuild -project HighlightBot.xcodeproj -scheme HighlightBot -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`. Expected: `** BUILD SUCCEEDED **`.
- Anything written only for verification lives under `/tmp`, never in the repo.
- Colours and metrics come from `AppPalette` and `ScreenMetrics` (`HighlightBot/Features/RootView.swift`). Yellow marks trim edits and green marks slow-mo, as in `ClipEditorScreen`.
- Time text uses `TrimRangeBar.timeText(_:)` (`m:ss.t`).

## Dispatch plan (subagent-driven)

Each task gets a fresh subagent with this plan, the spec, the task text, and its "Interfaces" block. A wave starts when the previous wave's commits are on the branch.

| Wave | Tasks | Parallel? | Notes |
| --- | --- | --- | --- |
| 1 | 1, 4 | yes (2 agents) | Disjoint files: Task 1 moves `SlowMotionSegment`; Task 4 adds `isMontage` |
| 2 | 2 | no | `ClipEdit` needs public `SlowMotionSegment` |
| 3 | 3, 5 | yes (2 agents) | Draft model; editor mode. Disjoint files |
| 4 | 6 | no | Exporter needs `MontageItem` and `ClipEdit` |
| 5 | 7 | no | Montage screen needs editor mode + exporter |
| 6 | 8 | no | Library entry + grid badge |
| 7 | 9 | no (orchestrator) | Device verification |

---

## Task 1: Move `SlowMotionSegment` into `HighlightCore` with tests

**Files:**
- Create: `HighlightCore/Sources/HighlightCore/Clips/SlowMotionSegment.swift`
- Create: `HighlightCore/Tests/HighlightCoreTests/SlowMotionSegmentTests.swift`
- Modify: `HighlightBot/Capture/ClipTrimmer.swift:26-78` (delete the struct)
- Modify: `HighlightBot/Features/Editor/TrimRangeBar.swift:1-3` (add import)

**Interfaces:**
- Produces: `public struct SlowMotionSegment` with the same members as today, all public, plus `Codable`.

- [ ] **Step 1: Write the failing tests**

```swift
// HighlightCore/Tests/HighlightCoreTests/SlowMotionSegmentTests.swift
import Foundation
import Testing
@testable import HighlightCore

@Suite("SlowMotionSegment")
struct SlowMotionSegmentTests {
    @Test("scaledDuration divides by rate")
    func scaled() {
        let segment = SlowMotionSegment(start: 2, end: 3, rate: 0.5)
        #expect(segment.duration == 1)
        #expect(segment.scaledDuration == 2)
    }

    @Test("addedDuration is the stretch in place and the whole scaled length on replay")
    func added() {
        let segment = SlowMotionSegment(start: 2, end: 3, rate: 0.25)
        #expect(segment.addedDuration == 3)
        #expect(segment.addedDuration(replay: false) == 3)
        #expect(segment.addedDuration(replay: true) == 4)
    }

    @Test("contains is half-open")
    func contains() {
        let segment = SlowMotionSegment(start: 2, end: 3, rate: 0.5)
        #expect(segment.contains(2))
        #expect(segment.contains(2.99))
        #expect(!segment.contains(3))
        #expect(!segment.contains(1.99))
    }

    @Test("centered puts defaultDuration in the middle and shrinks for short ranges")
    func centered() {
        let wide = SlowMotionSegment.centered(in: 0, 10)
        #expect(abs(wide.start - 4.5) < 1e-9)
        #expect(abs(wide.end - 5.5) < 1e-9)
        #expect(wide.rate == SlowMotionSegment.defaultRate)

        let narrow = SlowMotionSegment.centered(in: 0, 0.5)
        #expect(abs(narrow.start - 0) < 1e-9)
        #expect(abs(narrow.end - 0.5) < 1e-9)
    }

    @Test("clamped moves the segment inside the range keeping the minimum length")
    func clamped() {
        let past = SlowMotionSegment(start: 8, end: 9.5, rate: 0.5).clamped(to: 0, 9)
        #expect(past.start == 8)
        #expect(past.end == 9)

        let squeezed = SlowMotionSegment(start: 5, end: 6, rate: 0.5).clamped(to: 0, 5.1)
        #expect(abs(squeezed.end - 5.1) < 1e-9)
        #expect(abs(squeezed.start - (5.1 - SlowMotionSegment.minimumDuration)) < 1e-9)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let segment = SlowMotionSegment(start: 1.5, end: 2.75, rate: 0.15)
        let data = try JSONEncoder().encode(segment)
        #expect(try JSONDecoder().decode(SlowMotionSegment.self, from: data) == segment)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `HighlightCore/`): `swift test --filter SlowMotionSegmentTests`
Expected: compile error, `cannot find 'SlowMotionSegment' in scope`.

- [ ] **Step 3: Add the public struct to HighlightCore**

```swift
// HighlightCore/Sources/HighlightCore/Clips/SlowMotionSegment.swift
import Foundation

/// A stretch of a clip, in source seconds, that plays back slower than real
/// time. `rate` is the playback speed (0.5 = half speed), so the segment
/// occupies `duration / rate` seconds in the finished clip.
public struct SlowMotionSegment: Equatable, Sendable, Codable {
    public var start: Double
    public var end: Double
    public var rate: Float

    public init(start: Double, end: Double, rate: Float) {
        self.start = start
        self.end = end
        self.rate = rate
    }

    /// Speeds offered for a slow-mo segment. Same options as the player's
    /// speed menu minus 100%, which would be no slow-mo at all.
    public static let rates: [Float] = [0.5, 0.25, 0.15]
    public static let defaultRate: Float = 0.5
    /// Length of a freshly inserted segment, before the user adjusts it.
    public static let defaultDuration: Double = 1.0
    /// Shortest allowed segment; the editor enforces the same floor on its handles.
    public static let minimumDuration: Double = 0.25

    public var duration: Double { max(end - start, 0) }

    /// Seconds the segment lasts once slowed.
    public var scaledDuration: Double { duration / Double(rate) }

    /// Extra seconds the slow-mo adds to the finished clip. In-place stretch
    /// replaces the segment's source duration; replay keeps the 1× pass and
    /// appends `scaledDuration`.
    public var addedDuration: Double { addedDuration(replay: false) }

    public func addedDuration(replay: Bool) -> Double {
        replay ? scaledDuration : scaledDuration - duration
    }

    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }

    /// `defaultDuration` seconds centred in `start...end` (shrunk if the range
    /// is shorter than that).
    public static func centered(in start: Double, _ end: Double, rate: Float = defaultRate) -> SlowMotionSegment {
        let length = min(defaultDuration, max(end - start, 0))
        let mid = (start + end) / 2
        return SlowMotionSegment(start: mid - length / 2, end: mid + length / 2, rate: rate)
    }

    /// Moves the segment inside `start...end`, keeping `minimumDuration` when
    /// the range allows it. Used when the trim handles move past the segment.
    public func clamped(to start: Double, _ end: Double, minimumDuration: Double = minimumDuration) -> SlowMotionSegment {
        var result = self
        let floor = min(minimumDuration, max(end - start, 0))
        result.end = min(max(result.end, start + floor), end)
        result.start = max(min(result.start, result.end - floor), start)
        return result
    }
}
```

- [ ] **Step 4: Delete the app copy and fix imports**

In `HighlightBot/Capture/ClipTrimmer.swift` delete the whole `struct SlowMotionSegment { ... }` block (lines 26–78, from the `/// A stretch of the clip` comment through its closing brace). The file already has `import HighlightCore`.

In `HighlightBot/Features/Editor/TrimRangeBar.swift` add `import HighlightCore` after `import AVFoundation` (imports stay alphabetical: `AVFoundation`, `HighlightCore`, `SwiftUI`, `UIKit`).

`ClipEditorScreen.swift` and `SpeedMenu.swift` already import `HighlightCore`; nothing to do there.

- [ ] **Step 5: Run core tests**

Run (from `HighlightCore/`): `swift test`
Expected: all suites pass, including the six new `SlowMotionSegment` tests.

- [ ] **Step 6: Build the app**

Run (repo root): `xcodegen generate && xcodebuild -project HighlightBot.xcodeproj -scheme HighlightBot -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`. If `TrimRangeBar.swift` reports `cannot find type 'SlowMotionSegment'`, the import in Step 4 is missing.

- [ ] **Step 7: Commit**

```bash
git add HighlightCore/Sources/HighlightCore/Clips/SlowMotionSegment.swift HighlightCore/Tests/HighlightCoreTests/SlowMotionSegmentTests.swift HighlightBot/Capture/ClipTrimmer.swift HighlightBot/Features/Editor/TrimRangeBar.swift HighlightBot.xcodeproj
git commit -m "Move SlowMotionSegment into HighlightCore and cover it with tests"
```

---

## Task 2: `ClipEdit` value type

**Files:**
- Create: `HighlightCore/Sources/HighlightCore/Clips/ClipEdit.swift`
- Create: `HighlightCore/Tests/HighlightCoreTests/ClipEditTests.swift`

**Interfaces:**
- Consumes: `SlowMotionSegment` (Task 1).
- Produces:
  ```swift
  public struct ClipEdit: Equatable, Sendable, Codable {
      public var start: Double
      public var end: Double
      public var slowMotion: SlowMotionSegment?
      public var isSlowMotionReplay: Bool
      public init(start: Double, end: Double, slowMotion: SlowMotionSegment? = nil, isSlowMotionReplay: Bool = false)
      public static func full(duration: Double) -> ClipEdit
      public static let edgeTolerance: Double   // 0.01
      public var selectedDuration: Double
      public var outputDuration: Double
      public func isTrimmed(clipDuration: Double) -> Bool
      public func hasChanges(clipDuration: Double) -> Bool
      public func clamped(toClipDuration duration: Double, minimumDuration: Double) -> ClipEdit
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// HighlightCore/Tests/HighlightCoreTests/ClipEditTests.swift
import Foundation
import Testing
@testable import HighlightCore

@Suite("ClipEdit")
struct ClipEditTests {
    @Test("full covers the whole clip and has no changes")
    func full() {
        let edit = ClipEdit.full(duration: 12)
        #expect(edit.start == 0)
        #expect(edit.end == 12)
        #expect(edit.slowMotion == nil)
        #expect(!edit.isSlowMotionReplay)
        #expect(!edit.hasChanges(clipDuration: 12))
        #expect(edit.outputDuration == 12)
    }

    @Test("outputDuration adds the in-place stretch")
    func outputInPlace() {
        let edit = ClipEdit(start: 2, end: 8, slowMotion: SlowMotionSegment(start: 4, end: 5, rate: 0.5))
        #expect(edit.selectedDuration == 6)
        #expect(edit.outputDuration == 7)
    }

    @Test("outputDuration appends the whole scaled segment on replay")
    func outputReplay() {
        let edit = ClipEdit(start: 2, end: 8, slowMotion: SlowMotionSegment(start: 4, end: 5, rate: 0.25), isSlowMotionReplay: true)
        #expect(edit.outputDuration == 10)
    }

    @Test("replay flag without a segment adds nothing")
    func replayWithoutSegment() {
        let edit = ClipEdit(start: 0, end: 5, slowMotion: nil, isSlowMotionReplay: true)
        #expect(edit.outputDuration == 5)
        #expect(!edit.hasChanges(clipDuration: 5))
    }

    @Test("isTrimmed ignores movement inside the edge tolerance")
    func trimmedTolerance() {
        #expect(!ClipEdit(start: 0.005, end: 9.995).isTrimmed(clipDuration: 10))
        #expect(ClipEdit(start: 0.5, end: 10).isTrimmed(clipDuration: 10))
        #expect(ClipEdit(start: 0, end: 9.5).isTrimmed(clipDuration: 10))
    }

    @Test("hasChanges is true with only a slow-mo segment")
    func changesWithSlowMotion() {
        let edit = ClipEdit(start: 0, end: 10, slowMotion: SlowMotionSegment(start: 4, end: 5, rate: 0.5))
        #expect(edit.hasChanges(clipDuration: 10))
    }

    @Test("clamped fits a stale edit into a shorter file")
    func clampedShorter() throws {
        let stale = ClipEdit(start: 1, end: 12, slowMotion: SlowMotionSegment(start: 10, end: 11.5, rate: 0.5))
        let fitted = stale.clamped(toClipDuration: 10, minimumDuration: 1)
        #expect(fitted.start == 1)
        #expect(fitted.end == 10)
        let segment = try #require(fitted.slowMotion)
        #expect(segment.end == 10)
        #expect(segment.start <= 10 - SlowMotionSegment.minimumDuration)
    }

    @Test("clamped pulls start back when it would leave less than the minimum")
    func clampedStart() {
        let edit = ClipEdit(start: 9.8, end: 12).clamped(toClipDuration: 10, minimumDuration: 1)
        #expect(edit.end == 10)
        #expect(abs(edit.start - 9) < 1e-9)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let edit = ClipEdit(start: 1, end: 4, slowMotion: SlowMotionSegment(start: 2, end: 3, rate: 0.5), isSlowMotionReplay: true)
        let data = try JSONEncoder().encode(edit)
        #expect(try JSONDecoder().decode(ClipEdit.self, from: data) == edit)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `HighlightCore/`): `swift test --filter ClipEditTests`
Expected: compile error, `cannot find 'ClipEdit' in scope`.

- [ ] **Step 3: Implement**

```swift
// HighlightCore/Sources/HighlightCore/Clips/ClipEdit.swift
import Foundation

/// The trim and slow-mo settings for one clip, in source seconds. The editor
/// produces one of these; `ClipTrimmer` renders one for a single clip and the
/// montage exporter renders a sequence of them.
public struct ClipEdit: Equatable, Sendable, Codable {
    public var start: Double
    public var end: Double
    public var slowMotion: SlowMotionSegment?
    /// With a segment: play the trim at 1×, then replay the segment slow.
    /// Meaningless (and treated as false) without a segment.
    public var isSlowMotionReplay: Bool

    public init(start: Double, end: Double, slowMotion: SlowMotionSegment? = nil, isSlowMotionReplay: Bool = false) {
        self.start = start
        self.end = end
        self.slowMotion = slowMotion
        self.isSlowMotionReplay = isSlowMotionReplay
    }

    /// The whole clip, untouched.
    public static func full(duration: Double) -> ClipEdit {
        ClipEdit(start: 0, end: max(duration, 0))
    }

    /// A handle within this many seconds of the clip edge counts as untouched.
    /// Matches the editor's snapping.
    public static let edgeTolerance: Double = 0.01

    public var selectedDuration: Double { max(end - start, 0) }

    /// Seconds the rendered clip will run: the selection plus whatever the
    /// slow-mo stretch (or appended replay) adds.
    public var outputDuration: Double {
        guard let slowMotion else { return selectedDuration }
        return selectedDuration + slowMotion.addedDuration(replay: isSlowMotionReplay)
    }

    public func isTrimmed(clipDuration: Double) -> Bool {
        start > Self.edgeTolerance || end < clipDuration - Self.edgeTolerance
    }

    /// True once a handle has moved or slow-mo has been added.
    public func hasChanges(clipDuration: Double) -> Bool {
        isTrimmed(clipDuration: clipDuration) || slowMotion != nil
    }

    /// Fits the edit into `0...duration`, keeping at least `minimumDuration`
    /// selected when the clip allows it. For edits made against a record whose
    /// `duration` disagrees with the file, or a clip that has since been
    /// trimmed.
    public func clamped(toClipDuration duration: Double, minimumDuration: Double) -> ClipEdit {
        var result = self
        result.end = min(max(end, 0), duration)
        let latestStart = max(result.end - minimumDuration, 0)
        result.start = min(max(start, 0), latestStart)
        result.slowMotion = slowMotion?.clamped(to: result.start, result.end)
        if result.slowMotion == nil {
            result.isSlowMotionReplay = false
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `HighlightCore/`): `swift test --filter ClipEditTests`
Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add HighlightCore/Sources/HighlightCore/Clips/ClipEdit.swift HighlightCore/Tests/HighlightCoreTests/ClipEditTests.swift
git commit -m "Add ClipEdit value type for trim and slow-mo settings"
```

---

## Task 3: `MontageItem` and `MontageDraft`

**Files:**
- Create: `HighlightCore/Sources/HighlightCore/Clips/MontageDraft.swift`
- Create: `HighlightCore/Tests/HighlightCoreTests/MontageDraftTests.swift`

**Interfaces:**
- Consumes: `ClipRecord`, `ClipEdit` (Task 2).
- Produces:
  ```swift
  public struct MontageItem: Identifiable, Equatable, Sendable {
      public let clip: ClipRecord
      public var edit: ClipEdit
      public var id: UUID { clip.id }
      public init(clip: ClipRecord, edit: ClipEdit? = nil)
      public var outputDuration: Double
      public var hasChanges: Bool
  }
  public struct MontageDraft: Equatable, Sendable {
      public static let minimumClipCount: Int   // 2
      public private(set) var items: [MontageItem]
      public init(clips: [ClipRecord])                      // oldest first
      public var totalDuration: Double
      public var isReordered: Bool
      public var hasEdits: Bool
      public var hasChanges: Bool                          // isReordered || hasEdits
      public mutating func move(fromOffsets: IndexSet, toOffset: Int)
      public mutating func update(_ edit: ClipEdit, for id: UUID)
      public func item(withID id: UUID) -> MontageItem?
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// HighlightCore/Tests/HighlightCoreTests/MontageDraftTests.swift
import Foundation
import Testing
@testable import HighlightCore

@Suite("MontageDraft")
struct MontageDraftTests {
    /// A clip captured `seconds` after the epoch.
    private func clip(at seconds: TimeInterval, duration: TimeInterval = 10, id: UUID = UUID()) -> ClipRecord {
        ClipRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: seconds),
            duration: duration,
            fileName: "\(Int(seconds)).mp4",
            thumbnailFileName: nil,
            triggerSource: .tap,
            sizeBytes: 1
        )
    }

    @Test("init orders clips oldest first regardless of input order")
    func oldestFirst() {
        let newest = clip(at: 300)
        let oldest = clip(at: 100)
        let middle = clip(at: 200)
        let draft = MontageDraft(clips: [newest, oldest, middle])
        #expect(draft.items.map(\.clip.id) == [oldest.id, middle.id, newest.id])
        #expect(!draft.isReordered)
        #expect(!draft.hasChanges)
    }

    @Test("init breaks timestamp ties by id so the order is stable")
    func stableTies() {
        let a = clip(at: 100, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = clip(at: 100, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(MontageDraft(clips: [b, a]).items.map(\.id) == [a.id, b.id])
        #expect(MontageDraft(clips: [a, b]).items.map(\.id) == [a.id, b.id])
    }

    @Test("items start as full-length edits")
    func fullEdits() {
        let draft = MontageDraft(clips: [clip(at: 1, duration: 7), clip(at: 2, duration: 9)])
        #expect(draft.items.map(\.edit) == [.full(duration: 7), .full(duration: 9)])
        #expect(draft.totalDuration == 16)
        #expect(!draft.hasEdits)
    }

    @Test("move reorders like List.onMove and flags the draft as reordered")
    func move() {
        let clips = [clip(at: 1), clip(at: 2), clip(at: 3)]
        var draft = MontageDraft(clips: clips)
        draft.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(draft.items.map(\.id) == [clips[2].id, clips[0].id, clips[1].id])
        #expect(draft.isReordered)
        #expect(draft.hasChanges)
    }

    @Test("moving back to the original order clears isReordered")
    func moveBack() {
        let clips = [clip(at: 1), clip(at: 2)]
        var draft = MontageDraft(clips: clips)
        draft.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        draft.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(!draft.isReordered)
    }

    @Test("update replaces one item's edit and changes the total")
    func update() {
        let clips = [clip(at: 1, duration: 10), clip(at: 2, duration: 10)]
        var draft = MontageDraft(clips: clips)
        let edit = ClipEdit(start: 2, end: 6, slowMotion: SlowMotionSegment(start: 3, end: 4, rate: 0.5))
        draft.update(edit, for: clips[1].id)
        #expect(draft.item(withID: clips[1].id)?.edit == edit)
        #expect(draft.item(withID: clips[0].id)?.edit == .full(duration: 10))
        #expect(draft.totalDuration == 15)
        #expect(draft.hasEdits)
        #expect(draft.hasChanges)
    }

    @Test("update for an unknown id is a no-op")
    func updateUnknown() {
        var draft = MontageDraft(clips: [clip(at: 1)])
        let before = draft
        draft.update(ClipEdit(start: 1, end: 2), for: UUID())
        #expect(draft == before)
    }

    @Test("item hasChanges follows its edit")
    func itemChanges() {
        let record = clip(at: 1, duration: 10)
        #expect(!MontageItem(clip: record).hasChanges)
        #expect(MontageItem(clip: record, edit: ClipEdit(start: 1, end: 10)).hasChanges)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `HighlightCore/`): `swift test --filter MontageDraftTests`
Expected: compile error, `cannot find 'MontageDraft' in scope`.

- [ ] **Step 3: Implement**

```swift
// HighlightCore/Sources/HighlightCore/Clips/MontageDraft.swift
import Foundation

/// One clip in a montage with the trim/slow-mo the user has chosen for it.
/// Nothing is rendered until the montage is exported, so `edit` can change
/// any number of times.
public struct MontageItem: Identifiable, Equatable, Sendable {
    public let clip: ClipRecord
    public var edit: ClipEdit

    public var id: UUID { clip.id }

    /// `edit` defaults to the whole clip.
    public init(clip: ClipRecord, edit: ClipEdit? = nil) {
        self.clip = clip
        self.edit = edit ?? .full(duration: clip.duration)
    }

    /// Seconds this clip contributes to the finished montage.
    public var outputDuration: Double { edit.outputDuration }

    /// True once the user has trimmed this clip or given it slow-mo.
    public var hasChanges: Bool { edit.hasChanges(clipDuration: clip.duration) }
}

/// The montage being built: ordered items plus the edit for each. Pure state;
/// the screen renders it and the exporter consumes `items`.
public struct MontageDraft: Equatable, Sendable {
    /// Fewer than this and there is nothing to sequence.
    public static let minimumClipCount = 2

    public private(set) var items: [MontageItem]
    /// Order the draft started with, so `isReordered` can be answered after
    /// the user drags things around and back.
    private let initialOrder: [UUID]

    /// Oldest clip first. Ties on `createdAt` fall back to the id so two
    /// launches with the same clips produce the same order.
    public init(clips: [ClipRecord]) {
        let sorted = clips.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        items = sorted.map { MontageItem(clip: $0) }
        initialOrder = items.map(\.id)
    }

    /// Seconds the finished montage will run.
    public var totalDuration: Double {
        items.reduce(0) { $0 + $1.outputDuration }
    }

    public var isReordered: Bool { items.map(\.id) != initialOrder }

    public var hasEdits: Bool { items.contains(where: \.hasChanges) }

    /// Anything worth a "discard?" prompt.
    public var hasChanges: Bool { isReordered || hasEdits }

    /// Same contract as SwiftUI's `onMove`.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Replaces the edit on the item with `id`. Unknown ids are ignored.
    public mutating func update(_ edit: ClipEdit, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].edit = edit
    }

    public func item(withID id: UUID) -> MontageItem? {
        items.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `HighlightCore/`): `swift test --filter MontageDraftTests`
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add HighlightCore/Sources/HighlightCore/Clips/MontageDraft.swift HighlightCore/Tests/HighlightCoreTests/MontageDraftTests.swift
git commit -m "Add MontageDraft and MontageItem to HighlightCore"
```

---

## Task 4: `isMontage` flag on `ClipRecord` and `Clip`

**Files:**
- Modify: `HighlightCore/Sources/HighlightCore/Clips/ClipRecord.swift`
- Modify: `HighlightCore/Tests/HighlightCoreTests/ClipAssemblerTests.swift:100-151`
- Modify: `HighlightBot/App/Clip.swift`
- Modify: `HighlightBot/Features/Editor/ClipEditorScreen.swift:693-706` (the "Save as New Clip" copy)

**Interfaces:**
- Produces: `ClipRecord.isMontage: Bool` (default `false`), `ClipRecord.with(tags:isStarred:isMontage:)`, `Clip.isMontage`.

- [ ] **Step 1: Extend the existing Codable tests**

In `ClipAssemblerTests.swift`, change the three `ClipRecord` tests:

```swift
    @Test("ClipRecord round-trips through JSON with a flat trigger source")
    func clipRecordCodable() throws {
        let record = ClipRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 20,
            fileName: "clip.mp4",
            thumbnailFileName: "clip.jpg",
            triggerSource: .hardwareButton,
            sizeBytes: 12_345,
            tags: ["Hockey", "Playoffs"],
            isStarred: true,
            isMontage: true
        )
        let data = try JSONEncoder().encode(record)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"triggerSource\":\"hardware\""))
        let decoded = try JSONDecoder().decode(ClipRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.tags == ["Hockey", "Playoffs"])
        #expect(decoded.isStarred)
        #expect(decoded.isMontage)
    }

    @Test("ClipRecord decodes legacy JSON without tags, isStarred, or isMontage")
    func clipRecordLegacyDecode() throws {
        let json = """
        {"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","createdAt":0,"duration":20,"fileName":"clip.mp4","triggerSource":"tap","sizeBytes":1}
        """
        let decoded = try JSONDecoder().decode(ClipRecord.self, from: Data(json.utf8))
        #expect(decoded.tags.isEmpty)
        #expect(decoded.isStarred == false)
        #expect(decoded.isMontage == false)
        #expect(decoded.thumbnailFileName == nil)
    }

    @Test("ClipRecord.with replaces only user metadata")
    func clipRecordWith() {
        let record = ClipRecord(
            id: UUID(),
            createdAt: .now,
            duration: 5,
            fileName: "a.mp4",
            thumbnailFileName: nil,
            triggerSource: .tap,
            sizeBytes: 1
        )
        let tagged = record.with(tags: ["Golf"])
        #expect(tagged.tags == ["Golf"])
        #expect(tagged.isStarred == false)
        #expect(tagged.isMontage == false)
        #expect(tagged.id == record.id)
        let starred = tagged.with(isStarred: true)
        #expect(starred.tags == ["Golf"])
        #expect(starred.isStarred)
        let montage = starred.with(isMontage: true)
        #expect(montage.isStarred)
        #expect(montage.isMontage)
        #expect(montage.tags == ["Golf"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `HighlightCore/`): `swift test --filter ClipAssemblerTests`
Expected: compile error, `extra argument 'isMontage' in call`.

- [ ] **Step 3: Update `ClipRecord`**

Replace `HighlightCore/Sources/HighlightCore/Clips/ClipRecord.swift` with:

```swift
import Foundation

/// Persisted clip metadata (value type). The app's SwiftData model maps to
/// and from this.
public struct ClipRecord: Sendable, Codable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let createdAt: Date
    /// Clip length in seconds.
    public let duration: TimeInterval
    /// File name relative to the clips directory, e.g. `2026-09-18T20-11-03Z-3F2A.mp4`.
    public let fileName: String
    /// Thumbnail file name relative to the clips directory, if one was generated.
    public let thumbnailFileName: String?
    /// Which trigger produced the clip.
    public let triggerSource: TriggerSourceID
    /// Size of the clip file in bytes.
    public let sizeBytes: Int64
    /// User tags (sport or anything else). Normalized via `ClipTag`.
    public let tags: [String]
    /// User favourite flag.
    public let isStarred: Bool
    /// True for a clip the montage editor exported from several source clips.
    public let isMontage: Bool

    public init(
        id: UUID,
        createdAt: Date,
        duration: TimeInterval,
        fileName: String,
        thumbnailFileName: String?,
        triggerSource: TriggerSourceID,
        sizeBytes: Int64,
        tags: [String] = [],
        isStarred: Bool = false,
        isMontage: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.triggerSource = triggerSource
        self.sizeBytes = sizeBytes
        self.tags = tags
        self.isStarred = isStarred
        self.isMontage = isMontage
    }

    /// Copy with different user metadata. Capture fields are immutable.
    public func with(tags: [String]? = nil, isStarred: Bool? = nil, isMontage: Bool? = nil) -> ClipRecord {
        ClipRecord(
            id: id,
            createdAt: createdAt,
            duration: duration,
            fileName: fileName,
            thumbnailFileName: thumbnailFileName,
            triggerSource: triggerSource,
            sizeBytes: sizeBytes,
            tags: tags ?? self.tags,
            isStarred: isStarred ?? self.isStarred,
            isMontage: isMontage ?? self.isMontage
        )
    }

    // MARK: - Codable

    // Custom decoding so records written before `tags` / `isStarred` /
    // `isMontage` existed still decode (missing keys → defaults).
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, duration, fileName, thumbnailFileName, triggerSource, sizeBytes, tags, isStarred, isMontage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        fileName = try container.decode(String.self, forKey: .fileName)
        thumbnailFileName = try container.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        triggerSource = try container.decode(TriggerSourceID.self, forKey: .triggerSource)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        isMontage = try container.decodeIfPresent(Bool.self, forKey: .isMontage) ?? false
    }
}
```

- [ ] **Step 4: Run core tests**

Run (from `HighlightCore/`): `swift test`
Expected: all pass.

- [ ] **Step 5: Update the SwiftData model**

In `HighlightBot/App/Clip.swift`:

After `var isStarred: Bool = false` add:

```swift
    /// Exported by the montage editor. Same migration note as `tags`.
    var isMontage: Bool = false
```

In `init(record:)` after `isStarred = record.isStarred` add:

```swift
        isMontage = record.isMontage
```

In `var record: ClipRecord` after `isStarred: isStarred` add `,` and:

```swift
            isMontage: isMontage
```

- [ ] **Step 6: Carry the flag through "Save as New Clip"**

In `HighlightBot/Features/Editor/ClipEditorScreen.swift`, in `save(replacingOriginal:)`, the `ClipRecord(...)` for the copy currently ends with `isStarred: record.isStarred`. Change it to:

```swift
                        tags: record.tags,
                        isStarred: record.isStarred,
                        isMontage: record.isMontage
```

and update the comment above it to `// Same timestamp, tags, star, and montage flag so the copy sits beside its source.`

- [ ] **Step 7: Build the app**

Run (repo root): `xcodebuild -project HighlightBot.xcodeproj -scheme HighlightBot -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`. No `xcodegen generate` needed; no files were added.

- [ ] **Step 8: Commit**

```bash
git add HighlightCore/Sources/HighlightCore/Clips/ClipRecord.swift HighlightCore/Tests/HighlightCoreTests/ClipAssemblerTests.swift HighlightBot/App/Clip.swift HighlightBot/Features/Editor/ClipEditorScreen.swift
git commit -m "Add isMontage flag to ClipRecord and the Clip model"
```

---

## Task 5: `ClipEditorScreen` configure mode

**Files:**
- Modify: `HighlightBot/Features/Editor/ClipEditorScreen.swift`

**Interfaces:**
- Consumes: `ClipEdit` (Task 2), `ClipTrimmer.minimumDuration`.
- Produces:
  ```swift
  enum ClipEditorMode {
      case export(onComplete: (ClipEditOutcome) -> Void)
      case configure(onDone: (ClipEdit) -> Void)
  }
  // unchanged:
  ClipEditorScreen(record: ClipRecord, onComplete: @escaping (ClipEditOutcome) -> Void)
  // new:
  ClipEditorScreen(record: ClipRecord, edit: ClipEdit, onDone: @escaping (ClipEdit) -> Void)
  ```

- [ ] **Step 1: Add the mode enum and replace the stored closure**

Above `struct ClipEditorScreen: View {` (after the `ClipEditOutcome` enum), add:

```swift
/// How the editor hands back its result.
enum ClipEditorMode {
    /// Save re-encodes and writes a clip, replacing the original or adding a copy.
    case export(onComplete: (ClipEditOutcome) -> Void)
    /// Done returns the edit without encoding; the caller applies it later.
    /// Used by the montage builder, where clips are rendered together at the end.
    case configure(onDone: (ClipEdit) -> Void)
}
```

Replace

```swift
struct ClipEditorScreen: View {
    let record: ClipRecord
    let onComplete: (ClipEditOutcome) -> Void
```

with

```swift
struct ClipEditorScreen: View {
    let record: ClipRecord
    let mode: ClipEditorMode
```

Update the doc comment paragraph that begins `/// Present with `.fullScreenCover`.` to:

```swift
/// Present with `.fullScreenCover`. In `.export` mode `onComplete` fires before
/// dismissal so the presenter can refresh its copy of the record. In
/// `.configure` mode nothing is encoded: Done hands the `ClipEdit` back and
/// the montage builder renders it later.
```

- [ ] **Step 2: Seed state from a `ClipEdit`**

Change the state declarations so init owns the initial values:

```swift
    @State private var start: Double
    @State private var end: Double
    @State private var slowMotion: SlowMotionSegment?
    /// When a segment exists, play the trim at 1× then replay the segment slow.
    @State private var isSlowMotionReplay: Bool
```

(`start` loses its `= 0`, `isSlowMotionReplay` loses its `= false`.)

Replace the existing `init(record:onComplete:)` with:

```swift
    /// Single-clip editing from the player or Library: Save re-encodes.
    init(record: ClipRecord, onComplete: @escaping (ClipEditOutcome) -> Void) {
        self.init(record: record, edit: .full(duration: record.duration), mode: .export(onComplete: onComplete))
    }

    /// Montage child: starts from `edit` and hands the result to `onDone`
    /// without encoding anything.
    init(record: ClipRecord, edit: ClipEdit, onDone: @escaping (ClipEdit) -> Void) {
        self.init(record: record, edit: edit, mode: .configure(onDone: onDone))
    }

    private init(record: ClipRecord, edit: ClipEdit, mode: ClipEditorMode) {
        self.record = record
        self.mode = mode
        let duration = max(record.duration, 0.01)
        // A saved edit may predate a trim of this clip; keep it inside the file.
        let seeded = edit.clamped(toClipDuration: duration, minimumDuration: ClipTrimmer.minimumDuration)
        _duration = State(initialValue: duration)
        _start = State(initialValue: seeded.start)
        _end = State(initialValue: seeded.end)
        _slowMotion = State(initialValue: seeded.slowMotion)
        _isSlowMotionReplay = State(initialValue: seeded.slowMotion != nil && seeded.isSlowMotionReplay)
    }
```

- [ ] **Step 3: Add derived helpers**

In `// MARK: - Derived`, after `hasChanges`, add:

```swift
    private var isConfiguring: Bool {
        if case .configure = mode { return true }
        return false
    }

    /// The trim and slow-mo as they stand, for the configure mode's Done.
    private var currentEdit: ClipEdit {
        ClipEdit(
            start: start,
            end: end,
            slowMotion: slowMotion,
            isSlowMotionReplay: slowMotion != nil && isSlowMotionReplay
        )
    }
```

- [ ] **Step 4: Swap the top-right button by mode**

In `topBar`, replace the trailing `Button { player.pause(); showSaveOptions = true } ...` (the whole Save button including its modifiers) with:

```swift
            switch mode {
            case .export:
                Button {
                    player.pause()
                    showSaveOptions = true
                } label: {
                    Text("Save")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(hasChanges ? Color.yellow : Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!hasChanges)
                .accessibilityHint(hasChanges ? "" : "Move a handle or add slow-mo first")
            case .configure(let onDone):
                // Always enabled: resetting a clip to full length is a valid edit.
                Button {
                    player.pause()
                    onDone(currentEdit)
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.yellow)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Keeps this trim for the montage")
            }
```

- [ ] **Step 5: Adjust the hint text**

Replace `hintText` with:

```swift
    private var hintText: String {
        let saveNote = isConfiguring
            ? "Done keeps the edit for the montage; nothing is encoded yet."
            : "Saving re-encodes the clip."
        if slowMotion == nil {
            return "Drag the handles to trim. \(saveNote)"
        }
        if isSlowMotionReplay {
            return "The clip plays at full speed, then the green range replays in slow-mo. \(saveNote)"
        }
        return "Yellow handles trim; green handles bound the slow-mo. \(saveNote)"
    }
```

- [ ] **Step 6: Guard `save` to export mode**

At the top of `private func save(replacingOriginal: Bool) async`, before the `guard let clip = ...`, add:

```swift
        guard case .export(let onComplete) = mode else { return }
```

The later `onComplete(outcome)` call now refers to this local binding; no other change.

- [ ] **Step 7: Build the app**

Run (repo root): `xcodebuild -project HighlightBot.xcodeproj -scheme HighlightBot -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`. `ClipPlayerScreen` and `LibraryScreen` still compile against the unchanged `init(record:onComplete:)`.

- [ ] **Step 8: Smoke-test export mode in the Simulator**

Run the `HighlightBot` scheme on an iPhone simulator. Library → long-press a clip → Trim. Confirm: Save is dimmed until a handle moves, the confirmation dialog still offers Replace/Save as New, the hint still ends "Saving re-encodes the clip.", and Save as New produces a new clip. (Configure mode is exercised in Task 7.)

- [ ] **Step 9: Commit**

```bash
git add HighlightBot/Features/Editor/ClipEditorScreen.swift
git commit -m "Add a configure mode to ClipEditorScreen that returns a ClipEdit"
```

---

## Task 6: `MontageComposition` and `MontageExporter`

**Files:**
- Create: `HighlightBot/Features/Montage/MontageComposition.swift`
- Create: `HighlightBot/Features/Montage/MontageExporter.swift`
- Modify: `HighlightBot/Capture/ClipTrimmer.swift` (`validate`, expose `preset(for:)` and `duration(of:)`)
- Modify: `HighlightBot/Capture/ClipExporter.swift:128-162` (`runExport` gains `videoComposition`)

**Interfaces:**
- Consumes: `MontageItem`, `MontageDraft.minimumClipCount`, `ClipEdit`, `SlowMotionSegment`, `ExportedClip`, `ExportError`, `TrimError`, `ClipExporter.runExport/writeThumbnail/fileSize`.
- Produces:
  ```swift
  enum MontageError: LocalizedError { case tooFewClips(minimum: Int); case missingFile(String); case clip(index: Int, underlying: any Error) }
  enum MontageComposition {
      struct Built { let composition: AVMutableComposition; let videoComposition: AVMutableVideoComposition }
      static func build(_ items: [MontageItem]) async throws -> Built
      static func fitTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, into renderSize: CGSize) -> CGAffineTransform
  }
  final class MontageExporter: Sendable {
      init(clipsDirectory: URL)
      func export(_ items: [MontageItem], baseName: String) async throws -> ExportedClip
  }
  static func ClipTrimmer.validate(_ edit: ClipEdit) throws
  static func ClipTrimmer.preset(for asset: AVAsset) async -> String          // was private
  static func ClipTrimmer.duration(of asset: AVAsset) async -> Double?        // was private
  static func ClipExporter.runExport(asset:preset:timeRange:videoComposition:to:)
  ```

- [ ] **Step 1: Share validation and helpers from `ClipTrimmer`**

In `HighlightBot/Capture/ClipTrimmer.swift`:

Add this static method inside `final class ClipTrimmer`, right after `static let minimumDuration: Double = 1.0`:

```swift
    /// The checks `trim` runs before touching AVFoundation, for callers that
    /// render several edits at once. Throws `TrimError`.
    static func validate(_ edit: ClipEdit) throws {
        guard edit.start >= 0, edit.end > edit.start else { throw TrimError.rangeOutOfBounds }
        // Allow a hair of slack so a handle sitting exactly at the floor passes.
        guard edit.end - edit.start >= minimumDuration - 0.01 else {
            throw TrimError.rangeTooShort(minimum: minimumDuration)
        }
        if let slowMotion = edit.slowMotion {
            guard slowMotion.rate > 0, slowMotion.rate < 1,
                  slowMotion.end > slowMotion.start,
                  slowMotion.start >= edit.start - 0.01, slowMotion.end <= edit.end + 0.01 else {
                throw TrimError.slowMotionOutOfRange
            }
        }
    }
```

In `trim(...)`, replace the two `guard` statements and the `if let slowMotion { guard ... }` block at the top (everything before `let clock = ContinuousClock()`) with:

```swift
        try Self.validate(ClipEdit(start: start, end: end, slowMotion: slowMotion, isSlowMotionReplay: replay))
```

Change `private static func preset(for asset: AVAsset) async -> String` to `static func preset(for asset: AVAsset) async -> String` and `private static func duration(of asset: AVAsset) async -> Double?` to `static func duration(of asset: AVAsset) async -> Double?`. Update the `preset` doc comment to end with `Shared with `MontageExporter`.`

- [ ] **Step 2: Let `runExport` take a video composition**

In `HighlightBot/Capture/ClipExporter.swift`, change the signature and body of `runExport`:

```swift
    /// Exports `asset` (or just `timeRange` of it) to an `.mp4` at `outputURL`,
    /// replacing any existing file. `videoComposition` is applied when given
    /// (the montage uses one for per-clip orientation). Shared with
    /// `ClipTrimmer` and `MontageExporter`.
    static func runExport(
        asset: AVAsset,
        preset: String,
        timeRange: CMTimeRange? = nil,
        videoComposition: AVVideoComposition? = nil,
        to outputURL: URL
    ) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ExportError.exportSessionUnavailable
        }
        session.shouldOptimizeForNetworkUse = true
        if let timeRange {
            session.timeRange = timeRange
        }
        if let videoComposition {
            session.videoComposition = videoComposition
        }
```

The rest of the method (the `if #available(iOS 18, *)` block) is unchanged. Existing callers pass arguments by label, so they keep compiling.

- [ ] **Step 3: Write `MontageComposition`**

```swift
// HighlightBot/Features/Montage/MontageComposition.swift
import AVFoundation
import CoreGraphics
import Foundation
import HighlightCore

/// Builds the composition a montage export renders.
///
/// Video and audio each get one composition track; items are appended in
/// order at a running cursor. Slow-mo is applied with `scaleTimeRange`
/// immediately after each item is inserted, before the cursor moves on, so a
/// later item is never shifted under an earlier scale. This is
/// `ClipTrimmer.composition(of:range:slowMotion:replay:)` generalised to N
/// items.
///
/// A video composition carries each item's orientation: one instruction per
/// item whose layer transform applies the source's `preferredTransform` and
/// letterboxes it into the first item's oriented frame. A single
/// `preferredTransform` on the track would render mixed portrait/landscape
/// sources wrong.
enum MontageComposition {
    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
    }

    static let timescale: CMTimeScale = 600

    static func build(_ items: [MontageItem]) async throws -> Built {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.exportFailed("Could not add a video track to the composition.")
        }
        let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var renderSize: CGSize?
        var frameDuration = CMTime(value: 1, timescale: 30)
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for item in items {
            let asset = AVURLAsset(url: item.clip.fileURL)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw TrimError.noVideoTrack
            }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            let (naturalSize, transform, frameRate) = try await sourceVideo.load(.naturalSize, .preferredTransform, .nominalFrameRate)

            // The first item decides the output frame and frame rate.
            let frame: CGSize
            if let existing = renderSize {
                frame = existing
            } else {
                let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
                frame = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                renderSize = frame
                if frameRate > 0 {
                    frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
                }
            }

            let edit = item.edit
            let range = CMTimeRange(start: time(edit.start), end: time(edit.end))
            let itemStart = cursor
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let sourceAudio, let audio {
                try audio.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            var itemDuration = range.duration

            if let slowMotion = edit.slowMotion {
                let clamped = slowMotion.clamped(to: edit.start, edit.end, minimumDuration: 0)
                let segment = CMTimeRange(start: time(clamped.start), duration: time(clamped.duration))
                let scaled = time(clamped.scaledDuration)
                if edit.isSlowMotionReplay {
                    // 1× pass, then the segment again, slowed.
                    let replayAt = cursor + range.duration
                    try video.insertTimeRange(segment, of: sourceVideo, at: replayAt)
                    if let sourceAudio, let audio {
                        try audio.insertTimeRange(segment, of: sourceAudio, at: replayAt)
                    }
                    composition.scaleTimeRange(CMTimeRange(start: replayAt, duration: segment.duration), toDuration: scaled)
                    itemDuration = range.duration + scaled
                } else {
                    // Composition time for this item starts at `cursor` where the
                    // source starts at `range.start`.
                    let slowAt = cursor + (segment.start - range.start)
                    composition.scaleTimeRange(CMTimeRange(start: slowAt, duration: segment.duration), toDuration: scaled)
                    itemDuration = range.duration - segment.duration + scaled
                }
            }

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
            layer.setTransform(fitTransform(naturalSize: naturalSize, preferredTransform: transform, into: frame), at: itemStart)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: itemStart, duration: itemDuration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            cursor = itemStart + itemDuration
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize ?? CGSize(width: 1920, height: 1080)
        videoComposition.frameDuration = frameDuration
        videoComposition.instructions = instructions
        return Built(composition: composition, videoComposition: videoComposition)
    }

    /// Orients `naturalSize` with `preferredTransform`, then scales it to fit
    /// inside `renderSize` and centres it. Sources that already match the
    /// render size get exactly `preferredTransform` moved to the origin.
    static func fitTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, into renderSize: CGSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        guard oriented.width > 0, oriented.height > 0 else { return preferredTransform }
        let scale = min(renderSize.width / oriented.width, renderSize.height / oriented.height)
        let dx = (renderSize.width - oriented.width * scale) / 2
        let dy = (renderSize.height - oriented.height * scale) / 2
        // Apply the source transform, drag the rotated frame's origin to zero,
        // scale, then centre. `concatenating` applies left to right.
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }
}
```

- [ ] **Step 4: Write `MontageExporter`**

```swift
// HighlightBot/Features/Montage/MontageExporter.swift
import AVFoundation
import Foundation
import HighlightCore

/// Errors from `MontageExporter` raised before any encoding starts.
enum MontageError: LocalizedError {
    case tooFewClips(minimum: Int)
    case missingFile(String)
    case clip(index: Int, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .tooFewClips(let minimum):
            "A montage needs at least \(minimum) clips."
        case .missingFile(let name):
            "\(name) is missing from this device."
        case .clip(let index, let underlying):
            "Clip \(index + 1): \(underlying.localizedDescription)"
        }
    }
}

/// Joins ordered `MontageItem`s into one `.mp4` (plus thumbnail) in
/// `clipsDirectory`. Each item contributes its trimmed range with its slow-mo
/// applied the same way `ClipTrimmer` does for a single clip. Always
/// re-encodes: cuts are not on keyframes and the sources may differ in codec
/// or orientation. The output codec follows the first clip (HEVC stays HEVC).
final class MontageExporter: Sendable {
    let clipsDirectory: URL

    /// `clipsDirectory` is Documents/Clips; created if missing.
    init(clipsDirectory: URL) {
        self.clipsDirectory = clipsDirectory
        try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
    }

    /// Writes `clipsDirectory/<baseName>.mp4`. Source files are not modified.
    func export(_ items: [MontageItem], baseName: String) async throws -> ExportedClip {
        guard items.count >= MontageDraft.minimumClipCount else {
            throw MontageError.tooFewClips(minimum: MontageDraft.minimumClipCount)
        }
        for (index, item) in items.enumerated() {
            guard FileManager.default.fileExists(atPath: item.clip.fileURL.path) else {
                throw MontageError.missingFile(item.clip.fileName)
            }
            do {
                try ClipTrimmer.validate(item.edit)
            } catch {
                throw MontageError.clip(index: index, underlying: error)
            }
        }

        let clock = ContinuousClock()
        let started = clock.now
        let outputURL = clipsDirectory.appending(path: baseName + ".mp4")
        let expectedDuration = items.reduce(0) { $0 + $1.outputDuration }
        let preset = await ClipTrimmer.preset(for: AVURLAsset(url: items[0].clip.fileURL))
        Log.export.info("Exporting montage of \(items.count) clips (\(expectedDuration, format: .fixed(precision: 2))s) as \(baseName, privacy: .public) (\(preset, privacy: .public))")

        let built = try await MontageComposition.build(items)
        try await ClipExporter.runExport(
            asset: built.composition,
            preset: preset,
            videoComposition: built.videoComposition,
            to: outputURL
        )

        // Read timing and the thumbnail from the finished file so the record
        // matches what was actually written.
        let output = AVURLAsset(url: outputURL)
        let duration = await ClipTrimmer.duration(of: output) ?? expectedDuration
        let thumbnailURL = await ClipExporter.writeThumbnail(
            asset: output,
            at: min(0.5, duration / 2),
            baseName: baseName,
            clipsDirectory: clipsDirectory
        )
        let sizeBytes = ClipExporter.fileSize(at: outputURL)

        let seconds = (clock.now - started).timeInterval
        Log.export.info("Montage \(baseName, privacy: .public) took \(seconds, format: .fixed(precision: 3))s")
        return ExportedClip(fileURL: outputURL, thumbnailURL: thumbnailURL, duration: duration, sizeBytes: sizeBytes)
    }
}
```

- [ ] **Step 5: Regenerate and build**

Run (repo root): `xcodegen generate && xcodebuild -project HighlightBot.xcodeproj -scheme HighlightBot -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

If the compiler rejects `sourceVideo.load(.naturalSize, .preferredTransform, .nominalFrameRate)` as a tuple, split it into three sequential `try await sourceVideo.load(...)` calls.

If strict concurrency complains that `Built` crosses an isolation boundary, mark it `struct Built: @unchecked Sendable` with a comment: `// Built on one task and handed straight to the export session; never shared.`

- [ ] **Step 6: Re-run core tests (validate refactor touched nothing in Core, but confirm the tree is green)**

Run (from `HighlightCore/`): `swift test`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add HighlightBot/Features/Montage/MontageComposition.swift HighlightBot/Features/Montage/MontageExporter.swift HighlightBot/Capture/ClipTrimmer.swift HighlightBot/Capture/ClipExporter.swift HighlightBot.xcodeproj
git commit -m "Add MontageExporter that renders ordered ClipEdits into one clip"
```

---

## Task 7: `MontageEditorScreen`

**Files:**
- Create: `HighlightBot/Features/Montage/MontageEditorScreen.swift`

**Interfaces:**
- Consumes: `MontageDraft`, `MontageItem`, `ClipEditorScreen(record:edit:onDone:)` (Task 5), `MontageExporter` (Task 6), `ClipStore.insert`, `ClipStore.commonTags(of:)`, `ClipTrimmer.discard`, `ThumbnailImage`, `TrimRangeBar.timeText`, `Haptics`, `ScreenMetrics`, `AppPalette`, `ClipNaming.baseName(for:)`, `AppDirectories.clips`.
- Produces: `MontageEditorScreen(clips: [ClipRecord], onComplete: @escaping (ClipRecord) -> Void)`.

- [ ] **Step 1: Write the screen**

```swift
// HighlightBot/Features/Montage/MontageEditorScreen.swift
import HighlightCore
import SwiftUI

/// Full-screen montage builder. Lists the chosen clips in order (oldest first
/// to start), lets the user drag them into a new order and tap one to trim it
/// or add slow-mo in `ClipEditorScreen`. Per-clip edits live in the draft,
/// not on disk, so a clip can be reopened and tweaked. The check mark renders
/// every clip's edit in sequence as one new clip flagged `isMontage`.
///
/// Present with `.fullScreenCover`. `onComplete` fires with the saved record
/// before dismissal; the store has already been updated.
struct MontageEditorScreen: View {
    let onComplete: (ClipRecord) -> Void

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var draft: MontageDraft
    @State private var editingItem: MontageItem?
    @State private var isExporting = false
    @State private var showDiscardConfirm = false
    @State private var statusMessage: String?

    init(clips: [ClipRecord], onComplete: @escaping (ClipRecord) -> Void) {
        _draft = State(initialValue: MontageDraft(clips: clips))
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                clipList
                footer
            }
            .padding(.horizontal, ScreenMetrics.horizontal)
            .disabled(isExporting)

            if isExporting {
                exportingOverlay
            }
        }
        .statusBarHidden(true)
        .interactiveDismissDisabled(isExporting)
        .fullScreenCover(item: $editingItem) { item in
            ClipEditorScreen(record: item.clip, edit: item.edit) { edit in
                draft.update(edit, for: item.id)
            }
        }
        .confirmationDialog("Discard this montage?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                dismiss()
            }
        } message: {
            Text("Your clip order and edits are lost. The original clips are not changed.")
        }
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.top, 60)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: statusMessage)
        .animation(.easeInOut(duration: 0.2), value: isExporting)
        .task(id: statusMessage) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                if draft.hasChanges {
                    showDiscardConfirm = true
                } else {
                    dismiss()
                }
            } label: {
                Text("Cancel")
                    .font(.body)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Montage")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            Button {
                Task { await exportMontage() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppPalette.onFill)
                    .frame(width: 34, height: 34)
                    .background(AppPalette.confirm, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save montage")
            .accessibilityHint("Exports the clips in this order as one new clip")
        }
        .padding(.vertical, 12)
    }

    /// Drag handles come from active edit mode; reordering uses UIKit's
    /// reorder control, which VoiceOver exposes as a "Reorder" action. Row
    /// taps use `onTapGesture` because a `Button` label can swallow the
    /// reorder press. No selection binding, so edit mode adds no check marks.
    // VERIFY: in iOS 17 `List` with `editMode = .active` and `.onMove` shows
    // grab handles and still delivers `onTapGesture` to row content.
    private var clipList: some View {
        List {
            ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
                MontageRow(index: index, item: item)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingItem = item
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .padding(.vertical, 4)
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 8))
                    .accessibilityAddTraits(.isButton)
            }
            .onMove { source, destination in
                draft.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .environment(\.defaultMinListRowHeight, 70)
        .tint(.white)
        .animation(.easeInOut(duration: 0.15), value: draft.items.map(\.id))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(draft.items.count) clips")
                Spacer()
                Text("\(TrimRangeBar.timeText(draft.totalDuration)) total")
                    .foregroundStyle(draft.hasEdits ? Color.yellow : Color.white.opacity(0.85))
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))

            Text("Drag the handles to reorder. Tap a clip to trim it or add slow-mo. Saving re-encodes everything into one new clip.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var exportingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Exporting montage…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(28)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Export

    /// Renders the draft, indexes the result as a new clip stamped now, and
    /// hands it to the presenter. Failures keep the draft so the user can
    /// retry or cancel.
    private func exportMontage() async {
        isExporting = true
        defer { isExporting = false }

        let now = Date.now
        let baseName = ClipNaming.baseName(for: now)
        let exporter = MontageExporter(clipsDirectory: AppDirectories.clips)
        do {
            let exported = try await exporter.export(draft.items, baseName: baseName)
            let record = ClipRecord(
                id: UUID(),
                createdAt: now,
                duration: exported.duration,
                fileName: exported.fileURL.lastPathComponent,
                thumbnailFileName: exported.thumbnailFileName,
                triggerSource: .ui,
                sizeBytes: exported.sizeBytes,
                // Only what every source shares; the user can add more afterwards.
                tags: ClipStore.commonTags(of: draft.items.map(\.clip.tags)),
                isStarred: false,
                isMontage: true
            )
            do {
                try container.clipStore.insert(record)
            } catch {
                ClipTrimmer.discard(exported)
                throw error
            }
            container.lastClip = record
            Haptics.saved()
            onComplete(record)
            dismiss()
        } catch {
            Log.export.error("Montage failed: \(String(describing: error), privacy: .public)")
            Haptics.error()
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// One clip in the montage list: position, thumbnail, capture time, and the
/// length it contributes (yellow once edited, tortoise when it has slow-mo).
private struct MontageRow: View {
    let index: Int
    let item: MontageItem

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20)

            ThumbnailImage(fileName: item.clip.thumbnailFileName)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.clip.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text(TrimRangeBar.timeText(item.outputDuration))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.hasChanges ? Color.yellow : Color.white.opacity(0.7))
                    if item.edit.slowMotion != nil {
                        Image(systemName: "tortoise.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.green)
                            .accessibilityLabel("Has slow-mo")
                    }
                    if item.hasChanges {
                        Text("edited")
                            .font(.caption2)
                            .foregroundStyle(Color.yellow.opacity(0.8))
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the trim editor for this clip")
    }
}
```

- [ ] **Step 2: Regenerate and build**

Run (repo root): `xcodegen generate && xcodebuild -project HighlightBot.xcodeproj -scheme HighlightBot -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Temporary hook for a Simulator smoke test (do not commit)**

The Library entry point arrives in Task 8. To try the screen now, add a throwaway `.contextMenu` button to `LibraryScreen.clipCell(for:)` that sets a local `@State private var smokeMontage: MontageRequest?` with the two newest clips and presents `MontageEditorScreen` in a `.fullScreenCover(item:)`. Run on an iPhone simulator (the Simulator needs `replay.mov` in `HighlightBot/Resources/` to have clips; otherwise use a device). Confirm:
- Rows list oldest first, with grab handles; dragging reorders and the footer total stays the same.
- Tapping a row opens the editor with "Done" top-right; trimming and Done returns; the row shows the new length in yellow and "edited"; the footer total updates.
- Reopening the same row shows the saved handles and slow-mo.
- Cancel in the child editor leaves the saved edit alone.
- Cancel on the montage asks to discard only after a reorder or edit.
- Check mark shows the overlay, then dismisses; the new clip appears at the top of Library.

Revert the throwaway hook (`git checkout HighlightBot/Features/Library/LibraryScreen.swift`) before committing.

- [ ] **Step 4: Commit**

```bash
git status --short   # only MontageEditorScreen.swift and the xcodeproj should be listed
git add HighlightBot/Features/Montage/MontageEditorScreen.swift HighlightBot.xcodeproj
git commit -m "Add MontageEditorScreen with reorderable clips and per-clip editing"
```

---

## Task 8: Library entry point and grid badge

**Files:**
- Modify: `HighlightBot/Features/Library/LibraryScreen.swift`

**Interfaces:**
- Consumes: `MontageEditorScreen(clips:onComplete:)` (Task 7), `MontageDraft.minimumClipCount`, `ClipRecord.isMontage`.

- [ ] **Step 1: Add the request wrapper and state**

At the bottom of `LibraryScreen.swift`, after `private struct LibraryActionCircle`, add:

```swift
/// Clips handed to the montage builder, wrapped so `fullScreenCover(item:)`
/// has an identity per request.
private struct MontageRequest: Identifiable {
    let id = UUID()
    let clips: [ClipRecord]
}
```

In `LibraryScreen`'s state, after `@State private var showBulkTagPicker = false`, add:

```swift
    @State private var montageRequest: MontageRequest?
```

- [ ] **Step 2: Present the screen**

After the existing `.fullScreenCover(item: $trimmingRecord) { ... }` block add:

```swift
            .fullScreenCover(item: $montageRequest) { request in
                MontageEditorScreen(clips: request.clips) { record in
                    handleMontageSaved(record)
                }
            }
```

- [ ] **Step 3: Add the FAB above Tags**

In `selectionFABStack`, change

```swift
            if isSelecting {
                bulkTagFAB
                bulkStarFAB
                shareFAB
                deleteFAB
            }
```

to

```swift
            if isSelecting {
                montageFAB
                bulkTagFAB
                bulkStarFAB
                shareFAB
                deleteFAB
            }
```

After `private var bulkTagFAB: some View { ... }` add:

```swift
    private var canMakeMontage: Bool {
        selectedIDs.count >= MontageDraft.minimumClipCount
    }

    private var montageFAB: some View {
        Button {
            montageRequest = MontageRequest(clips: selectedRecords)
        } label: {
            LibraryActionCircle(systemImage: "scissors", tint: AppPalette.accent, enabled: canMakeMontage)
        }
        .buttonStyle(.plain)
        .disabled(!canMakeMontage)
        .accessibilityLabel("Make a montage from selected clips")
        .accessibilityHint(canMakeMontage ? "" : "Select at least \(MontageDraft.minimumClipCount) clips")
    }
```

- [ ] **Step 4: Handle completion**

After `private func handleEdit(_ outcome: ClipEditOutcome)` add:

```swift
    /// The montage screen already inserted the clip and set `lastClip`;
    /// `@Query` puts it at the top of the grid. Leave select mode and confirm.
    private func handleMontageSaved(_ record: ClipRecord) {
        exitSelection()
        statusMessage = "Montage saved · \(TrimRangeBar.timeText(record.duration))"
    }
```

Update the file's header comment (the `/// Grid of saved clips ...` block) to mention the new action, replacing `Select mode toggles membership in a set of clip IDs.` with `Select mode toggles membership in a set of clip IDs; with two or more selected, the scissors button opens the montage builder.`

- [ ] **Step 5: Badge montages in the grid**

In `ClipCell.body`, replace

```swift
                Image(systemName: Self.symbol(for: record.triggerSource))
                    .foregroundStyle(.secondary)
```

with

```swift
                Image(systemName: record.isMontage ? "film.stack" : Self.symbol(for: record.triggerSource))
                    .foregroundStyle(.secondary)
                    // The trigger glyph was never read out; only the montage one carries meaning.
                    .accessibilityHidden(!record.isMontage)
                    .accessibilityLabel("Montage")
```

- [ ] **Step 6: Build**

Run (repo root): `xcodebuild -project HighlightBot.xcodeproj -scheme HighlightBot -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Simulator check**

Run on an iPhone simulator with clips present. Library → Select: the scissors circle sits directly above the tag circle and is dimmed with 0 or 1 selected, enabled at 2. Tap it with three clips selected out of order → the montage lists them oldest first. Export → Library shows the toast, leaves select mode, and the new top cell shows `film.stack` in its caption row. Long-press the new clip → Trim → Save as New Clip → the copy also shows `film.stack`.

- [ ] **Step 8: Commit**

```bash
git add HighlightBot/Features/Library/LibraryScreen.swift
git commit -m "Open the montage builder from Library select mode and badge montages"
```

---

## Task 9: Device verification

**Files:** none (report only). Run on a physical iPhone in Release via the `HighlightBot` scheme so encode timing is representative.

- [ ] **Step 1: Build a montage from mixed sources**

Record two landscape clips and one portrait clip (rotate the phone before tapping save). Select all three → scissors → export. Play the result: the portrait clip is letterboxed inside the landscape frame, nothing is stretched or rotated, audio continues across cuts.

- [ ] **Step 2: Slow-mo in both modes in one montage**

Clip 1: trim to 3 s with an in-place 0.5× segment. Clip 2: full length with a 0.25× segment and Slow-mo replay on. Confirm the footer total equals the sum shown in each editor's "saves" figure, and the exported clip's duration in the grid cell matches the footer within 0.2 s.

- [ ] **Step 3: Edit round trip**

Open clip 1 again: handles and the green segment sit where they were left. Move the end handle, tap Cancel: the row's length is unchanged. Move it again, tap Done: the row updates.

- [ ] **Step 4: Codec follows the first clip**

With HEVC enabled in Settings record one clip; with H.264 record another. Montage HEVC-first and H.264-first. Check both play in Photos after Save to Photos. (Expected: the output codec matches the first clip; the log line "Exporting montage … (AVAssetExportPresetHEVCHighestQuality)" confirms which preset ran.)

- [ ] **Step 5: Failure path**

Build a draft, then delete one source clip from the Files app (Documents/Clips) while the montage screen is open. Tap the check mark: toast reads "<file>.mp4 is missing from this device.", the draft is still there, Cancel prompts to discard.

- [ ] **Step 6: Existing flows unchanged**

Player → Trim → Save → Replace Original still works and the player reloads. Library long-press → Trim → Save as New Clip still works. Select mode Tags/Star/Share/Delete still work with the extra FAB present in both portrait and landscape.

- [ ] **Step 7: Report**

Note encode wall time from the `Montage … took` log line for a ~30 s three-clip montage and any VERIFY items that needed a change. If the `List` reorder or tap behaviour differed from Task 7's VERIFY note, file the follow-up (switch to `.draggable`/`.dropDestination`) rather than patching in this task.

---

## Self-review

**Spec coverage**
- Multi-select entry, circular scissors button above Tags, ≥ 2 clips → Task 8.
- Oldest-first initial order → `MontageDraft.init` (Task 3), listed in Task 7.
- Hold-and-drag reorder → Task 7 (`List` edit mode + `onMove`).
- Tap a clip → same editor, same controls → Task 5 `configure` mode, Task 7 cover.
- Confirm on a clip stores config without encoding; re-tap to tweak → Tasks 5 and 7 (`draft.update`, seeded `init(record:edit:onDone:)`).
- Check mark exports a new clip with `createdAt = now` → Task 7 `exportMontage`.
- `isMontage` flag in the DB like `isStarred` → Task 4.
- Mixed orientation, slow-mo in-place and replay, codec follows first clip → Task 6.
- Error handling (too few, missing file, invalid edit, insert failure cleanup) → Tasks 6 and 7.
- Tests for Core logic; simulator build per app task; device checklist → Tasks 1–4, 5–8, 9.

**Type consistency**
- `ClipEdit(start:end:slowMotion:isSlowMotionReplay:)` used identically in Tasks 2, 5, 6.
- `MontageDraft.move(fromOffsets:toOffset:)`, `update(_:for:)`, `items`, `totalDuration`, `hasEdits`, `hasChanges`, `minimumClipCount` used in Tasks 3, 7, 8.
- `ClipTrimmer.validate(_:)`, `preset(for:)`, `duration(of:)` defined Task 6 Step 1, used Task 6 Step 4.
- `ClipExporter.runExport(asset:preset:timeRange:videoComposition:to:)` defined Task 6 Step 2, used Task 6 Step 4 with labels.
- `ClipEditorScreen(record:edit:onDone:)` defined Task 5, used Task 7.
- `MontageEditorScreen(clips:onComplete:)` defined Task 7, used Task 8.
- `ClipRecord.isMontage` defined Task 4, used Tasks 7 and 8.

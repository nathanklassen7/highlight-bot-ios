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
        guard !source.isEmpty else { return }
        let moving = source.sorted().map { items[$0] }
        let target = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) {
            items.remove(at: index)
        }
        for (offset, item) in moving.enumerated() {
            items.insert(item, at: target + offset)
        }
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

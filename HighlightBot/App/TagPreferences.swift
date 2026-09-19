import Foundation
import HighlightCore
import Observation
import os

/// Small tag lists that outlive individual clips, kept in `UserDefaults`.
///
/// - `activeTags`: chosen on the Record screen; stamped onto every clip as it
///   is saved. Persisted so a session's sport survives relaunch until cleared.
/// - `rememberedTags`: every custom tag the user has ever added, so the
///   picker can still offer it after the last clip carrying it is deleted.
@MainActor
@Observable
final class TagPreferences {
    private static let activeKey = "activeTags"
    private static let rememberedKey = "rememberedTags"

    /// Tags applied to new clips. Always normalized and de-duplicated.
    var activeTags: [String] {
        didSet {
            guard activeTags != oldValue else { return }
            defaults.set(activeTags, forKey: Self.activeKey)
            remember(activeTags)
        }
    }

    /// Custom (non-sport) tags the user has used anywhere. Sorted for display.
    private(set) var rememberedTags: [String] {
        didSet {
            guard rememberedTags != oldValue else { return }
            defaults.set(rememberedTags, forKey: Self.rememberedKey)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeTags = ClipTag.normalized(defaults.stringArray(forKey: Self.activeKey) ?? [])
        rememberedTags = ClipTag.sortedForDisplay(
            ClipTag.normalized(defaults.stringArray(forKey: Self.rememberedKey) ?? [])
                .filter { !ClipTag.isSuggestedSport($0) }
        )
    }

    /// Adds any non-sport entries of `tags` to `rememberedTags`. Call from
    /// every place a user adds a tag (picker, bulk tag, Record).
    func remember(_ tags: [String]) {
        let custom = ClipTag.normalized(tags).filter { !ClipTag.isSuggestedSport($0) }
        guard !custom.isEmpty else { return }
        let merged = ClipTag.merge(rememberedTags, custom)
        rememberedTags = ClipTag.sortedForDisplay(merged)
    }

    /// Drops `tag` from `rememberedTags`. Clips that still carry it are not
    /// changed, so it reappears in the picker while any clip uses it.
    func forget(_ tag: String) {
        rememberedTags = ClipTag.removing(tag, from: rememberedTags)
    }

    /// Non-sport tags to offer under "Custom" in the picker: remembered
    /// tags plus whatever is on clips or active right now.
    func previousTags(usedOnClips: [String]) -> [String] {
        let all = ClipTag.merge(ClipTag.merge(rememberedTags, usedOnClips), activeTags)
        return ClipTag.sortedForDisplay(all.filter { !ClipTag.isSuggestedSport($0) })
    }
}

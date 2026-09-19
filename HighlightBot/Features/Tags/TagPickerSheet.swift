import HighlightCore
import SwiftUI

/// The one tag picker. Record uses it for the active recording tags; Library
/// and Player use it for a clip (or a bulk selection). Always lists every
/// suggested sport, then previously used custom tags, then a field to create
/// a new one.
///
/// Present with `.sheet`. The picker works on a draft; `onSave` receives the
/// normalized selection when the user taps Done. Cancel discards the draft.
/// Newly added custom tags are remembered in `TagPreferences` on save.
struct TagPickerSheet: View {
    let title: String
    /// Bulk mode: the sheet starts empty and the caller unions the result.
    let footnote: String?
    let onSave: ([String]) -> Void

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var selection: [String]
    @State private var previous: [String] = []
    @State private var customText = ""
    @FocusState private var customFieldFocused: Bool

    init(
        title: String = "Tags",
        initialSelection: [String],
        footnote: String? = nil,
        onSave: @escaping ([String]) -> Void
    ) {
        self.title = title
        self.footnote = footnote
        self.onSave = onSave
        _selection = State(initialValue: ClipTag.normalized(initialSelection))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    selectedSection
                    section("Sports") {
                        pillGrid(ClipTag.suggestedSports)
                    }
                    section("Custom") {
                        if !previous.isEmpty {
                            pillGrid(previous, forgettable: true)
                        }
                        customField
                    }
                    if let footnote {
                        Text(footnote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, ScreenMetrics.horizontal)
                .padding(.vertical, 12)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            previous = container.tagPreferences.previousTags(usedOnClips: container.clipStore.usedTags())
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var selectedSection: some View {
        if selection.isEmpty {
            Text("No tags selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            TagFlowLayout(spacing: 8) {
                ForEach(selection, id: \.self) { tag in
                    TagPill(tag: tag, size: .regular) {
                        remove(tag)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: selection)
        }
    }

    private func section<Content: View>(_ header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// `forgettable` adds a long-press menu that removes the tag from the
    /// remembered list (custom tags only).
    private func pillGrid(_ tags: [String], forgettable: Bool = false) -> some View {
        TagFlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                let selected = ClipTag.contains(selection, tag)
                Button {
                    toggle(tag)
                } label: {
                    HStack(spacing: 4) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                        }
                        Text(tag)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.onFill)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(TagStyle.color(for: tag).opacity(selected ? 1 : 0.45), in: Capsule())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if forgettable {
                        Button(role: .destructive) {
                            forget(tag)
                        } label: {
                            Label("Forget \"\(tag)\"", systemImage: "trash")
                        }
                    }
                }
                .accessibilityLabel(tag)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(selected ? "Removes the tag" : "Adds the tag")
            }
        }
    }

    private var customField: some View {
        HStack(spacing: 8) {
            TextField("New tag", text: $customText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($customFieldFocused)
                .onSubmit { addCustom() }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button("Add") { addCustom() }
                .buttonStyle(.borderedProminent)
                .disabled(ClipTag.normalize(customText) == nil)
        }
    }

    // MARK: - Actions

    private func toggle(_ tag: String) {
        if ClipTag.contains(selection, tag) {
            remove(tag)
        } else {
            selection = ClipTag.merge(selection, [tag])
        }
    }

    private func remove(_ tag: String) {
        selection = ClipTag.removing(tag, from: selection)
    }

    /// Removes a custom tag from the suggestions. The current selection is
    /// left alone so forgetting never silently edits the clip being tagged.
    private func forget(_ tag: String) {
        container.tagPreferences.forget(tag)
        withAnimation(.easeInOut(duration: 0.15)) {
            previous = ClipTag.removing(tag, from: previous)
        }
    }

    private func addCustom() {
        guard let tag = ClipTag.normalize(customText) else { return }
        selection = ClipTag.merge(selection, [tag])
        if !ClipTag.isSuggestedSport(tag) {
            previous = ClipTag.sortedForDisplay(ClipTag.merge(previous, [tag]))
        }
        customText = ""
        customFieldFocused = true
    }

    private func save() {
        let result = ClipTag.normalized(selection)
        container.tagPreferences.remember(result)
        onSave(result)
        dismiss()
    }
}

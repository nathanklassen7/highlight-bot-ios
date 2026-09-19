import SwiftUI

/// A tag rendered as a colored capsule. Used everywhere a tag is shown:
/// clip cells, filter bar, player chrome, Record overlay, and the picker.
struct TagPill: View {
    enum Size {
        /// Cells, filter bar, Record overlay.
        case compact
        /// Picker rows and the player.
        case regular
    }

    let tag: String
    var size: Size = .compact
    /// When false the pill is drawn at reduced opacity (picker: not chosen yet).
    var isSelected = true
    /// Shows a trailing "x" that calls this when tapped.
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: size == .compact ? 9 : 11, weight: .bold))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(tag)")
            }
        }
        .font(font)
        .foregroundStyle(AppPalette.onFill)
        .padding(.horizontal, size == .compact ? 8 : 12)
        .padding(.vertical, size == .compact ? 3 : 7)
        .background(TagStyle.color(for: tag).opacity(isSelected ? 1 : 0.45), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(onRemove == nil ? Text(tag) : Text("\(tag) tag"))
    }

    private var font: Font {
        switch size {
        case .compact: .caption2.weight(.semibold)
        case .regular: .subheadline.weight(.semibold)
        }
    }
}

/// Small "+N" capsule for tags that did not fit.
struct TagOverflowPill: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.18), in: Capsule())
            .accessibilityLabel("\(count) more tags")
    }
}

/// Up to `limit` pills followed by an overflow pill. Single line.
struct TagPillRow: View {
    let tags: [String]
    var limit = 2
    var size: TagPill.Size = .compact

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(limit), id: \.self) { tag in
                    TagPill(tag: tag, size: size)
                }
                if tags.count > limit {
                    TagOverflowPill(count: tags.count - limit)
                }
            }
        }
    }
}

/// Left-to-right wrapping layout for pills.
struct TagFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

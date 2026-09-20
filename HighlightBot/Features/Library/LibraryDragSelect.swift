import SwiftUI
import UIKit

/// Range-select math for the library grid: the first clip locks the mode
/// (add if it was unselected, remove if it was selected). The operation
/// applies to the contiguous slice of `orderedIDs` between that start clip
/// and the clip under the finger, against the selection at drag start.
/// Dragging back toward the start shrinks the slice; clips that leave it
/// revert to their baseline membership.
struct LibraryDragSelectSession: Equatable {
    enum Mode: Equatable {
        case add
        case remove
    }

    let mode: Mode
    let baseline: Set<UUID>
    let startID: UUID
    private(set) var endID: UUID

    init(startingAt id: UUID, isSelected: Bool, currentSelection: Set<UUID>) {
        mode = isSelected ? .remove : .add
        baseline = currentSelection
        startID = id
        endID = id
    }

    mutating func extend(to id: UUID) {
        endID = id
    }

    func selection(in orderedIDs: [UUID]) -> Set<UUID> {
        let range = Self.range(from: startID, to: endID, in: orderedIDs)
        switch mode {
        case .add: return baseline.union(range)
        case .remove: return baseline.subtracting(range)
        }
    }

    /// Inclusive slice of `orderedIDs` from `start` to `end`, either direction.
    static func range(from start: UUID, to end: UUID, in orderedIDs: [UUID]) -> Set<UUID> {
        guard let i = orderedIDs.firstIndex(of: start) else { return [start] }
        guard let j = orderedIDs.firstIndex(of: end) else { return [start] }
        let lo = min(i, j)
        let hi = max(i, j)
        return Set(orderedIDs[lo...hi])
    }
}

enum LibraryDragSelect {
    /// Thickness of the top/bottom auto-scroll bands, as a share of the
    /// visible height, clamped so small phones still have a usable zone and
    /// iPads don't steal half the screen.
    static let edgeRatio: CGFloat = 0.14
    static let minEdge: CGFloat = 56
    static let maxEdge: CGFloat = 96
    /// Points per second at the outer edge of the band.
    static let maxScrollSpeed: CGFloat = 980
    /// Horizontal translation (points) that separates a vertical scroll from
    /// drag-to-select. Kept small so a slight diagonal still selects; a
    /// straight flick stays under this and scrolls.
    static let horizontalSelectSlop: CGFloat = 2

    static func edgeWidth(for viewportHeight: CGFloat) -> CGFloat {
        min(max(viewportHeight * edgeRatio, minEdge), maxEdge)
    }

    /// Negative = scroll up (content moves down). Zero outside the bands.
    static func scrollVelocity(fingerY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let edge = edgeWidth(for: viewportHeight)
        guard viewportHeight > edge * 2 else { return 0 }
        if fingerY < edge {
            let progress = min((edge - fingerY) / edge, 1.5)
            return -maxScrollSpeed * progress
        }
        if fingerY > viewportHeight - edge {
            let progress = min((fingerY - (viewportHeight - edge)) / edge, 1.5)
            return maxScrollSpeed * progress
        }
        return 0
    }
}

/// Invisible UIKit view filling a grid cell so drag-select can hit-test real
/// frames while the scroll view is moving, which SwiftUI preferences lag.
private final class ClipHitAnchorView: UIView {
    var clipID: UUID?
}

private struct ClipHitAnchor: UIViewRepresentable {
    let id: UUID

    func makeUIView(context: Context) -> ClipHitAnchorView {
        let view = ClipHitAnchorView()
        view.clipID = id
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: ClipHitAnchorView, context: Context) {
        uiView.clipID = id
    }
}

extension View {
    /// Marks this cell as a drag-select target. No visual effect.
    func clipDragSelectTarget(id: UUID) -> some View {
        background { ClipHitAnchor(id: id) }
    }
}

/// Hosts the pan recognizer on the library `UIScrollView`. Added as a
/// background inside the `ScrollView` so it can walk up to the UIKit scroll
/// view SwiftUI created.
struct LibraryDragSelectBridge: UIViewRepresentable {
    var isEnabled: Bool
    var selectedIDs: Set<UUID>
    /// Visible grid order, newest-first as the library shows it. The drag
    /// range is a contiguous slice of this list.
    var orderedIDs: [UUID]
    var onSelectionChange: (Set<UUID>) -> Void

    func makeCoordinator() -> LibraryDragSelectController {
        LibraryDragSelectController()
    }

    func makeUIView(context: Context) -> LibraryDragSelectHostView {
        let view = LibraryDragSelectHostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.controller = context.coordinator
        return view
    }

    func updateUIView(_ uiView: LibraryDragSelectHostView, context: Context) {
        let controller = context.coordinator
        controller.isEnabled = isEnabled
        controller.selectedIDs = selectedIDs
        controller.orderedIDs = orderedIDs
        controller.onSelectionChange = onSelectionChange
        uiView.controller = controller
        uiView.bind()
    }

    static func dismantleUIView(_ uiView: LibraryDragSelectHostView, coordinator: LibraryDragSelectController) {
        coordinator.detach()
        uiView.controller = nil
    }
}

final class LibraryDragSelectHostView: UIView {
    var controller: LibraryDragSelectController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        bind()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        bind()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bind()
    }

    func bind() {
        controller?.attach(to: enclosingScrollView())
    }

    private func enclosingScrollView() -> UIScrollView? {
        var current: UIView? = superview
        while let view = current {
            if let scrollView = view as? UIScrollView { return scrollView }
            current = view.superview
        }
        return nil
    }
}

@MainActor
final class LibraryDragSelectController: NSObject, UIGestureRecognizerDelegate {
    var isEnabled = false {
        didSet {
            pan?.isEnabled = isEnabled
            if !isEnabled { endSession() }
        }
    }

    var selectedIDs: Set<UUID> = []
    var orderedIDs: [UUID] = []
    var onSelectionChange: ((Set<UUID>) -> Void)?

    private weak var scrollView: UIScrollView?
    private var pan: UIPanGestureRecognizer?
    private var session: LibraryDragSelectSession?
    /// Clip under the finger at touch-down, captured before translation so an
    /// upward drag still knows which cell the range starts on.
    private var touchDownID: UUID?
    private var lastPoint: CGPoint?
    private var scrollVelocity: CGFloat = 0
    private var scrollTask: Task<Void, Never>?

    func attach(to scrollView: UIScrollView?) {
        guard let scrollView else { return }
        if self.scrollView === scrollView, pan != nil {
            pan?.isEnabled = isEnabled
            return
        }
        detach()
        self.scrollView = scrollView
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = isEnabled
        scrollView.addGestureRecognizer(pan)
        scrollView.panGestureRecognizer.require(toFail: pan)
        self.pan = pan
    }

    func detach() {
        endSession()
        if let pan {
            pan.view?.removeGestureRecognizer(pan)
        }
        pan = nil
        scrollView = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled,
              touchDownID != nil,
              let pan = gestureRecognizer as? UIPanGestureRecognizer
        else { return false }
        let translation = pan.translation(in: pan.view)
        // A straight vertical drag is a scroll. Any real sideways component
        // (beyond jitter) claims the gesture for range-select, whether the
        // finger is heading down the grid or back up above the start clip.
        return abs(translation.x) > LibraryDragSelect.horizontalSelectSlop
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if isEnabled, let scrollView {
            touchDownID = clipID(at: touch.location(in: nil), in: scrollView)
        } else {
            touchDownID = nil
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: nil)
        switch gesture.state {
        case .began:
            beginSession()
            updateEnd(at: point)
            updateAutoScroll(at: point)
        case .changed:
            updateEnd(at: point)
            updateAutoScroll(at: point)
        case .ended, .cancelled, .failed:
            endSession()
        default:
            break
        }
    }

    private func beginSession() {
        guard let id = touchDownID else { return }
        session = LibraryDragSelectSession(
            startingAt: id,
            isSelected: selectedIDs.contains(id),
            currentSelection: selectedIDs
        )
        publish()
    }

    private func updateEnd(at point: CGPoint) {
        lastPoint = point
        guard var session, let scrollView else { return }
        guard let id = clipID(at: point, in: scrollView, nearestIfMiss: true) else { return }
        guard id != session.endID else { return }
        session.extend(to: id)
        self.session = session
        publish()
    }

    private func publish() {
        guard let session else { return }
        let next = session.selection(in: orderedIDs)
        if next != selectedIDs {
            selectedIDs = next
            onSelectionChange?(next)
        }
    }

    private func endSession() {
        scrollTask?.cancel()
        scrollTask = nil
        scrollVelocity = 0
        session = nil
        lastPoint = nil
        touchDownID = nil
    }

    private func updateAutoScroll(at point: CGPoint) {
        lastPoint = point
        guard let scrollView else {
            setScrollVelocity(0)
            return
        }
        let frame = scrollView.convert(scrollView.bounds, to: nil)
        setScrollVelocity(
            LibraryDragSelect.scrollVelocity(
                fingerY: point.y - frame.minY,
                viewportHeight: frame.height
            )
        )
    }

    private func setScrollVelocity(_ velocity: CGFloat) {
        scrollVelocity = velocity
        if velocity == 0 {
            scrollTask?.cancel()
            scrollTask = nil
            return
        }
        guard scrollTask == nil else { return }
        scrollTask = Task { @MainActor [weak self] in
            var lastTick = CACurrentMediaTime()
            while let self, !Task.isCancelled {
                let velocity = self.scrollVelocity
                if velocity == 0 { break }
                let now = CACurrentMediaTime()
                let dt = min(now - lastTick, 0.05)
                lastTick = now
                self.tickScroll(delta: velocity * dt)
                try? await Task.sleep(for: .milliseconds(8))
            }
            self?.scrollTask = nil
        }
    }

    private func tickScroll(delta: CGFloat) {
        guard let scrollView, abs(delta) > 0.05 else { return }
        let inset = scrollView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let next = min(max(scrollView.contentOffset.y + delta, minY), maxY)
        guard abs(next - scrollView.contentOffset.y) > 0.05 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: next), animated: false)
        scrollView.layoutIfNeeded()
        if let lastPoint {
            updateEnd(at: lastPoint)
        }
    }

    private func clipID(at windowPoint: CGPoint, in scrollView: UIScrollView, nearestIfMiss: Bool = false) -> UUID? {
        let anchors = clipAnchors(in: scrollView)
        let hits = anchors.filter { $0.frame.contains(windowPoint) }
        if let hit = hits.min(by: { $0.area < $1.area }) {
            return hit.id
        }
        guard nearestIfMiss, !anchors.isEmpty else { return nil }
        return anchors.min(by: { distance(from: windowPoint, to: $0.frame) < distance(from: windowPoint, to: $1.frame) })?.id
    }

    private func clipAnchors(in scrollView: UIScrollView) -> [(id: UUID, frame: CGRect, area: CGFloat)] {
        guard let window = scrollView.window else { return [] }
        var result: [(id: UUID, frame: CGRect, area: CGFloat)] = []
        func walk(_ view: UIView) {
            if let anchor = view as? ClipHitAnchorView,
               let id = anchor.clipID,
               view.bounds.width > 1,
               view.bounds.height > 1 {
                let frame = view.convert(view.bounds, to: window)
                result.append((id, frame, frame.width * frame.height))
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(scrollView)
        return result
    }

    /// Zero inside `rect`; otherwise the distance to the nearest edge.
    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

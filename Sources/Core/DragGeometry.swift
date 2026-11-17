import CoreGraphics
import Foundation

/// Where a drag has to start for the selection it leaves to count. SelectionReader ignores drags
/// that start outside the focused element, such as window drags. WebKit can report a page's frame
/// at the wrong origin: in Mail's reading pane the page and its scroll area were placed at the
/// window's bottom-left corner, outside the window, while the group above them had the right
/// position. So the first frame, from the element up through its ancestors, that really overlaps
/// the element's window is used.
enum DragGeometry {
    /// `chain` is the element's frame followed by its ancestors' frames, innermost first.
    static func containmentFrame(chain: [CGRect], window: CGRect?) -> CGRect? {
        guard let own = chain.first else { return nil }
        guard let window else { return own }
        return chain.first { overlaps($0, window) } ?? own
    }

    /// True when the two share an area, not just an edge.
    static func overlaps(_ frame: CGRect, _ window: CGRect) -> Bool {
        let overlap = frame.intersection(window)
        return !overlap.isNull && overlap.width >= 1 && overlap.height >= 1
    }
}

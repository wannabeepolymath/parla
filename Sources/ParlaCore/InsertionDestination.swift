import Foundation

/// Identity for a pending native paste, not a snapshot of the destination's
/// contents. Terminal output and editor updates can change text/cursor offsets
/// without moving keyboard focus. Replacement operations use separate guards.
struct InsertionDestination<Identity: Equatable> {
    let process: Int32?
    let window: Identity?
    let windowNumber: UInt32?
    let element: Identity?
    let selection: String?

    init(process: Int32?, window: Identity?, windowNumber: UInt32?, element: Identity?,
         selection: String? = nil) {
        self.process = process; self.window = window; self.windowNumber = windowNumber
        self.element = element; self.selection = selection
    }

    func matches(_ current: Self) -> Bool {
        guard let process, process == current.process else { return false }
        // Pasting replaces a selection. Do not overwrite text newly selected
        // during cleanup; an ordinary caret can move as terminal output grows.
        if let selected = current.selection, !selected.isEmpty, selected != selection { return false }

        let sameWindow: Bool?
        if let window, let other = current.window {
            sameWindow = window == other
        } else if let windowNumber, let other = current.windowNumber {
            // Window Server identity remains available when an app's AX bridge
            // is missing or becomes available during cleanup.
            sameWindow = windowNumber == other
        } else {
            sameWindow = nil
        }
        if sameWindow == false { return false }

        switch (element, current.element) {
        case let (before?, after?):
            return before == after
        case (nil, nil):
            if let sameWindow { return sameWindow }
            // Fully opaque apps retain the process-only fallback. If a known
            // window disappears, however, we cannot verify its replacement.
            return window == nil && current.window == nil
                && windowNumber == nil && current.windowNumber == nil
        default:
            // AX focus can appear/disappear while the same window keeps focus.
            // Do not mistake bridge availability for an actual field switch.
            return sameWindow == true
        }
    }
}

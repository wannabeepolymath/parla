/// Shared by menu and Hub through HubModel.clearHistory. Invalidation happens
/// even if durable history removal fails; it never cancels keyboard output.
enum HistoryClearAction {
    static func run(invalidateResult: () -> Void, clearHistory: () -> Void) {
        invalidateResult()
        clearHistory()
    }
}

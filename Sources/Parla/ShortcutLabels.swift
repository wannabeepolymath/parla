import Carbon
import Combine
import Foundation
import ParlaCore

/// One retained input-source observer for the Hub and its menu hints. Main only;
/// owns no settings and never rebinds the event tap or composes input text.
final class ShortcutLabels: NSObject {
    static let inputSourceDidChange = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
    @Published private(set) var revision = 0
    private(set) var formatter: ShortcutDisplayFormatter
    private let snapshot: () -> ShortcutDisplayFormatter
    private let center: NotificationCenter

    init(center: NotificationCenter = DistributedNotificationCenter.default(),
         snapshot: @escaping () -> ShortcutDisplayFormatter = ShortcutDisplayFormatter.current) {
        self.center = center
        self.snapshot = snapshot
        formatter = snapshot()
        super.init()
        if let distributed = center as? DistributedNotificationCenter {
            distributed.addObserver(self, selector: #selector(sourceChanged), name: Self.inputSourceDidChange,
                                    object: nil, suspensionBehavior: .deliverImmediately)
        } else {
            center.addObserver(self, selector: #selector(sourceChanged), name: Self.inputSourceDidChange, object: nil)
        }
    }

    deinit { center.removeObserver(self, name: Self.inputSourceDidChange, object: nil) }

    @objc private func sourceChanged(_ notification: Notification) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        } else {
            refresh()
        }
    }

    private func refresh() {
        formatter = snapshot()
        revision += 1
    }
}

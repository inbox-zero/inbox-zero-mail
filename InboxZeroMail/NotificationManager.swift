import AppKit
import MailCore
import MailFeatures
import UserNotifications

/// Manages macOS notifications for new mail and dock badge count.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var isAuthorized = false
    private var isForegroundActive = true
    private var knownUnreadThreadIDs: Set<MailThreadID> = []
    private var hasPrimedUnreadBaseline = false

    func setForegroundActive(_ isActive: Bool) {
        isForegroundActive = isActive
    }

    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.isAuthorized = granted
            }
        }
    }

    func handleReload(reason: MailReloadReason, threads: [MailThread]) {
        let unreadThreads = threads.filter(\.hasUnread)
        let unreadIDs = Set(unreadThreads.map(\.id))
        updateBadge(count: unreadThreads.count)

        guard hasPrimedUnreadBaseline else {
            knownUnreadThreadIDs = unreadIDs
            hasPrimedUnreadBaseline = true
            return
        }

        let newUnread = unreadThreads.filter { knownUnreadThreadIDs.contains($0.id) == false }
        knownUnreadThreadIDs = unreadIDs

        guard reason == .workspaceChange, isAuthorized, isForegroundActive == false else { return }

        scheduleNotification(for: Array(newUnread))
    }

    /// Update dock badge to reflect current unread count.
    func updateBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - Private

    private func scheduleNotification(for threads: [MailThread]) {
        guard threads.isEmpty == false else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default
        let identifier: String

        if threads.count == 1, let thread = threads.first {
            content.title = thread.participantSummary
            content.subtitle = thread.subject
            content.body = thread.snippet
            content.userInfo = ["threadID": thread.id.rawValue]
            identifier = "newmail-\(thread.id.rawValue)"
        } else {
            let visibleThreads = threads.prefix(3)
            content.title = "\(threads.count) new emails"
            content.body = visibleThreads
                .map { "\($0.participantSummary): \($0.subject)" }
                .joined(separator: "\n")
            identifier = "newmail-summary-\(UUID().uuidString)"
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification click — posted as a Notification so the app can open the thread.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let threadID = response.notification.request.content.userInfo["threadID"] as? String
        if let threadID {
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .openThreadFromNotification,
                    object: nil,
                    userInfo: ["threadID": threadID]
                )
            }
        }
        completionHandler()
    }

    /// Foreground reloads update the dock badge without presenting extra banners.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}

extension Notification.Name {
    static let openThreadFromNotification = Notification.Name("openThreadFromNotification")
}

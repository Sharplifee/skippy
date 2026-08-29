import SwiftUI
import ActivityKit
import UserNotifications
import BackgroundTasks

@main
struct SkipperApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = OfficeStore()

    var body: some Scene {
        WindowGroup {
            OfficeView()
                .environmentObject(store)
                .task { await store.start() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { app.registerForRemoteNotifications() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.connor.skippy.refresh", using: nil) { task in
            self.handleRefresh(task as! BGAppRefreshTask)
        }
        return true
    }

    func application(_ app: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task { try? await SkipperAPI.shared.register(deviceToken: hex) }
    }

    func application(_ app: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Registration without a device token still yields an install token, so
        // the app stays usable — it just cannot receive alerts.
        Task { try? await SkipperAPI.shared.register() }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            _ = try? await CommandPoller.shared.drain()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: "com.connor.skippy.refresh")
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}

// MARK: - Live Activity control

@MainActor
final class ActivityController: ObservableObject {
    static let shared = ActivityController()
    @Published private(set) var current: Activity<SkipperAttributes>?

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Starts the Activity and — critically — ships the per-Activity push token
    /// back to the server, then keeps shipping it every time it rotates. Without
    /// the rotation observer the Island goes dark after the first rotation with
    /// no error anywhere.
    func start(conversationId: String = "", initial: SkipperAttributes.ContentState) async {
        guard isAvailable else { return }
        if let existing = current {
            await update(initial)
            _ = existing
            return
        }
        do {
            let activity = try Activity.request(
                attributes: SkipperAttributes(agentName: "Skipper", conversationId: conversationId),
                content: .init(state: initial, staleDate: Date().addingTimeInterval(900)),
                pushType: .token)
            current = activity
            observeToken(activity)
        } catch {
            print("Live Activity request failed: \(error)")
        }
    }

    private func observeToken(_ activity: Activity<SkipperAttributes>) {
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                try? await SkipperAPI.shared.registerActivity(activityID: activity.id, pushToken: hex)
            }
        }
    }

    func update(_ state: SkipperAttributes.ContentState) async {
        guard let activity = current else { return }
        await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(900)))
    }

    func end() async {
        guard let activity = current else { return }
        try? await SkipperAPI.shared.endActivity(activityID: activity.id)
        await activity.end(nil, dismissalPolicy: .immediate)
        current = nil
    }
}

// MARK: - Device command queue consumer

actor CommandPoller {
    static let shared = CommandPoller()

    /// Drains whatever the server has queued for this device. Each command is
    /// leased, so a crash mid-command releases it back rather than losing it.
    @discardableResult
    func drain(max: Int = 5) async throws -> Int {
        var handled = 0
        for _ in 0..<max {
            guard let cmd = try await SkipperAPI.shared.claimCommand() else { break }
            let (ok, note) = await run(cmd)
            try await SkipperAPI.shared.completeCommand(id: cmd.id, ok: ok, result: note)
            handled += 1
        }
        return handled
    }

    private func run(_ cmd: DeviceCommand) async -> (Bool, String) {
        switch cmd.kind {
        case "shortcut":
            guard let name = cmd.payload?["name"]?.value,
                  let url = URL(string: "shortcuts://run-shortcut?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)")
            else { return (false, "shortcut command missing payload.name") }
            let opened = await MainActor.run { UIApplication.shared.canOpenURL(url) }
            guard opened else { return (false, "Shortcuts app cannot open \(name)") }
            await MainActor.run { UIApplication.shared.open(url) }
            return (true, "opened shortcut \(name)")

        case "notify":
            let body = cmd.payload?["body"]?.value ?? "Skipper"
            let content = UNMutableNotificationContent()
            content.title = cmd.payload?["title"]?.value ?? "Skipper"
            content.body = body
            let req = UNNotificationRequest(identifier: cmd.id, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(req)
                return (true, "local notification delivered")
            } catch {
                return (false, "notification failed: \(error.localizedDescription)")
            }

        case "ping":
            return (true, "device reachable at \(ISO8601DateFormatter().string(from: .now))")

        default:
            return (false, "no handler on device for kind '\(cmd.kind)'")
        }
    }
}

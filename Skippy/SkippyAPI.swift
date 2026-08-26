import Foundation
import UIKit

/// The only network layer in the app.
///
/// Skippy ships with NO credential. On first launch it calls `/register` with
/// nothing but a locally generated install id, receives a per-install token,
/// and uses that for every subsequent call. That is why this repo can be public:
/// there is no key in it to leak, and compromising one install exposes exactly
/// one install.
actor SkippyAPI {
    static let shared = SkippyAPI()

    private let base = URL(string: "https://lbvaosyfikkpvcwksiph.supabase.co/functions/v1/skippy-api")!

    private enum Keys {
        static let installID = "skippy.installID"
        static let installToken = "skippy.installToken"
    }

    // MARK: - Identity

    nonisolated var installID: String {
        if let existing = UserDefaults.standard.string(forKey: Keys.installID) { return existing }
        let fresh = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: Keys.installID)
        return fresh
    }

    private var installToken: String? {
        get { UserDefaults.standard.string(forKey: Keys.installToken) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.installToken) }
    }

    var isRegistered: Bool { installToken != nil }

    // MARK: - Transport

    private func post(_ action: String,
                      body: [String: Any],
                      authed: Bool = true) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(action))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 30

        if authed {
            guard let token = installToken else { throw SkippyError.notRegistered }
            req.setValue(token, forHTTPHeaderField: "x-install-token")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        // A rejected token means the install was revoked or the row was cleared.
        // Drop it so the next launch re-registers rather than failing forever.
        if code == 401 {
            installToken = nil
            throw SkippyError.unauthorized
        }
        guard (200..<300).contains(code) else {
            throw SkippyError.server(code, json["error"] as? String ?? "unknown")
        }
        return json
    }

    // MARK: - Registration

    /// Safe to call on every launch. Upserts, and preserves the existing token.
    @discardableResult
    func register(deviceToken: String? = nil) async throws -> String {
        var body: [String: Any] = [
            "install_id": installID,
            "platform": "ios",
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.connor.skippy",
            "environment": Self.apnsEnvironment,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ]
        if let deviceToken { body["device_token"] = deviceToken }

        let json = try await post("register", body: body, authed: false)
        guard let token = json["install_token"] as? String else { throw SkippyError.badResponse }
        installToken = token
        return token
    }

    /// A sandbox build must be pushed through Apple's sandbox host. Getting this
    /// wrong yields BadDeviceToken with no other symptom.
    nonisolated static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        guard let url = Bundle.main.appStoreReceiptURL else { return "production" }
        return url.lastPathComponent == "sandboxReceipt" ? "sandbox" : "production"
        #endif
    }

    // MARK: - Live Activities

    /// The per-Activity push token is NOT the device token, and it rotates.
    /// Every rotation must be sent or the server pushes into a dead token.
    func registerActivity(activityID: String, pushToken: String, taskID: String? = nil) async throws {
        var body: [String: Any] = ["activity_id": activityID, "push_token": pushToken]
        if let taskID { body["task_id"] = taskID }
        _ = try await post("activity", body: body)
    }

    func endActivity(activityID: String) async throws {
        _ = try await post("activity-end", body: ["activity_id": activityID])
    }

    // MARK: - The office

    func office(limit: Int = 25) async throws -> Office {
        let json = try await post("office", body: ["limit": limit])
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder.skippy.decode(Office.self, from: data)
    }

    func island() async throws -> SkippyAttributes.ContentState {
        let json = try await post("island", body: [:])
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(SkippyAttributes.ContentState.self, from: data)
    }

    @discardableResult
    func submit(intent: String, domain: String = "research", successTest: String? = nil) async throws -> String {
        var body: [String: Any] = ["intent": intent, "domain": domain]
        if let successTest { body["success_test"] = successTest }
        let json = try await post("submit", body: body)
        guard let id = json["task_id"] as? String else { throw SkippyError.badResponse }
        return id
    }

    // MARK: - Device command queue
    //
    // This is the mechanism behind server-armed device work. The queue lives on
    // the server with a lease; without this poller anything queued to the device
    // domain sits forever.

    func claimCommand() async throws -> DeviceCommand? {
        let json = try await post("claim-command", body: ["install_id": installID, "lease_s": 120])
        if json["none"] != nil || json["id"] == nil { return nil }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try? JSONDecoder.skippy.decode(DeviceCommand.self, from: data)
    }

    func completeCommand(id: String, ok: Bool, result: String) async throws {
        _ = try await post("complete-command", body: ["id": id, "ok": ok, "result": result])
    }
}

enum SkippyError: LocalizedError {
    case notRegistered
    case unauthorized
    case badResponse
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notRegistered:      return "Not registered yet"
        case .unauthorized:       return "Install token rejected — will re-register"
        case .badResponse:        return "Unexpected response shape"
        case .server(let c, let m): return "Server \(c): \(m)"
        }
    }
}

extension JSONDecoder {
    static let skippy: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let d = ISO8601DateFormatter.skippyFractional.date(from: s) { return d }
            if let d = ISO8601DateFormatter.skippyPlain.date(from: s) { return d }
            return Date()
        }
        return d
    }()
}

import ActivityKit
import Foundation

/// SINGLE SOURCE OF TRUTH for the Live Activity contract.
///
/// Compiled into BOTH the app and the widget extension. `ContentState` must
/// match the JSON returned by `maestro.island_state()` exactly. If a field name
/// or type drifts, iOS silently drops the push update — no error, no log, the
/// Island just stops moving. That silence is why this lives in one file.
public struct SkipperAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {

        public enum Phase: String, Codable, Hashable {
            case working, waiting, blocked, outOfBudget, failed, done

            public var glyph: String {
                switch self {
                case .working:     return "arrow.triangle.2.circlepath"
                case .waiting:     return "hand.raised.fill"
                case .blocked:     return "pause.circle.fill"
                case .outOfBudget: return "creditcard.trianglebadge.exclamationmark"
                case .failed:      return "exclamationmark.triangle.fill"
                case .done:        return "checkmark.circle.fill"
                }
            }

            public var label: String {
                switch self {
                case .working:     return "Working"
                case .waiting:     return "Needs you"
                case .blocked:     return "Paused"
                case .outOfBudget: return "Out of budget"
                case .failed:      return "Failed"
                case .done:        return "All clear"
                }
            }
        }

        public var phase: Phase
        public var headline: String
        public var runsActive: Int
        public var runsNeedingYou: Int
        public var budgetFraction: Double?
        public var costToday: Double?
        public var updatedAt: Date

        public init(phase: Phase = .done,
                    headline: String = "Nothing running",
                    runsActive: Int = 0,
                    runsNeedingYou: Int = 0,
                    budgetFraction: Double? = nil,
                    costToday: Double? = nil,
                    updatedAt: Date = .now) {
            self.phase = phase
            self.headline = headline
            self.runsActive = runsActive
            self.runsNeedingYou = runsNeedingYou
            self.budgetFraction = budgetFraction
            self.costToday = costToday
            self.updatedAt = updatedAt
        }

        /// Postgres sends ISO8601 with fractional seconds and the default
        /// decoder rejects those. A throwing decode here means a dropped push,
        /// so every field degrades to a default instead of failing.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phase = (try? c.decode(Phase.self, forKey: .phase)) ?? .done
            headline = (try? c.decode(String.self, forKey: .headline)) ?? "Nothing running"
            runsActive = (try? c.decode(Int.self, forKey: .runsActive)) ?? 0
            runsNeedingYou = (try? c.decode(Int.self, forKey: .runsNeedingYou)) ?? 0
            budgetFraction = try? c.decode(Double.self, forKey: .budgetFraction)
            costToday = try? c.decode(Double.self, forKey: .costToday)
            if let s = try? c.decode(String.self, forKey: .updatedAt) {
                updatedAt = ISO8601DateFormatter.skipperFractional.date(from: s)
                    ?? ISO8601DateFormatter.skipperPlain.date(from: s)
                    ?? .now
            } else {
                updatedAt = .now
            }
        }
    }

    public var agentName: String
    public var conversationId: String

    public init(agentName: String = "Skipper", conversationId: String = "") {
        self.agentName = agentName
        self.conversationId = conversationId
    }
}

public extension ISO8601DateFormatter {
    static let skipperFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let skipperPlain = ISO8601DateFormatter()
}

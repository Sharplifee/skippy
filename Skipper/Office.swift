import Foundation

/// Mirrors `maestro.office()`. One request returns the entire landscape, so the
/// screen never has to stitch five calls together and never shows two sections
/// that disagree with each other.
struct Office: Codable {
    var now: Date?
    var halted: Bool?
    var inFlight: [Task]
    var delegating: [Delegation]
    var needsYou: [Blocked]
    var queued: [Queued]
    var recent: [Completed]
    var findings: [Finding]
    var conversation: Conversation
    var agents: [Agent]
    var locks: [Lock]
    var budget: Budget?
    var island: SkipperAttributes.ContentState?
    var persona: Persona?

    enum CodingKeys: String, CodingKey {
        case now, halted, queued, recent, findings, conversation, agents
        case locks, budget, island, persona, delegating
        case inFlight = "in_flight"
        case needsYou = "needs_you"
    }

    struct Task: Codable, Identifiable {
        var id: String
        var intent: String
        var domain: String
        var status: String
        var agent: String?
        var attempt: Int?
        var of: Int?
        var role: String?
        var successTest: String?
        var leaseUntil: Date?

        enum CodingKeys: String, CodingKey {
            case id, intent, domain, status, agent, attempt, of, role
            case successTest = "success_test"
            case leaseUntil = "lease_until"
        }
    }

    /// A Maestro that has broken a request into steps. This is what makes the
    /// board show a plan unfolding rather than a flat list of jobs.
    struct Delegation: Codable, Identifiable {
        var id: String
        var intent: String
        var plan: String?
        var children: [Child]?

        struct Child: Codable, Hashable {
            var intent: String
            var domain: String
            var status: String
        }
    }

    struct Blocked: Codable, Identifiable {
        var id: String
        var intent: String
        var domain: String
        var status: String
        var why: String?
        var since: Date?
        var lastObserved: String?

        enum CodingKeys: String, CodingKey {
            case id, intent, domain, status, why, since
            case lastObserved = "last_observed"
        }
    }

    struct Queued: Codable, Identifiable {
        var id: String
        var intent: String
        var domain: String
        var blockedByParent: Bool?

        enum CodingKeys: String, CodingKey {
            case id, intent, domain
            case blockedByParent = "blocked_by_parent"
        }
    }

    struct Completed: Codable, Identifiable {
        var id: String
        var intent: String
        var domain: String
        var status: String
        var completedAt: Date?
        var costUsd: Double?
        var attempts: Int?
        var observed: String?

        enum CodingKeys: String, CodingKey {
            case id, intent, domain, status, observed, attempts
            case completedAt = "completed_at"
            case costUsd = "cost_usd"
        }
    }

    struct Finding: Codable, Identifiable {
        var id: String
        var question: String
        var answer: String
        var sources: [String]?
        var createdAt: Date?

        /// The verifier's ruling. This is the only trustworthy grade:
        /// pass | fail | unclear | bad_test.
        var verdict: String?
        /// What the verifier actually observed when it re-fetched.
        var verifierNote: String?
        /// verified | rejected | bad criterion | unconfirmed | checking
        var standing: String?
        /// Single flag the UI can trust.
        var verified: Bool?

        /// The generator's opinion of itself. Never display this as a grade —
        /// no component grades itself. Kept for diagnostics only.
        var selfReportedConfidence: String?

        enum CodingKeys: String, CodingKey {
            case id, question, answer, sources, verdict, standing, verified
            case createdAt = "created_at"
            case verifierNote = "verifier_note"
            case selfReportedConfidence = "self_reported_confidence"
        }
    }

    struct Conversation: Codable {
        var id: String?
        var turns: [Turn]

        struct Turn: Codable, Identifiable {
            var id: String
            var role: String
            var surface: String
            var content: Content
            var taskId: String?
            var at: Date?

            enum CodingKeys: String, CodingKey {
                case id, role, surface, content, at
                case taskId = "task_id"
            }

            /// Turn content is free-form JSON: a user message, a plan the
            /// Maestro made, or a verdict from the verifier.
            struct Content: Codable, Hashable {
                var kind: String?
                var text: String?
                var note: String?
                var verdict: String?
                var observed: String?
                var intent: String?
                var domain: String?
                var steps: [Step]?

                struct Step: Codable, Hashable {
                    var intent: String
                    var domain: String
                }

                var display: String {
                    if let text { return text }
                    if let note { return note }
                    if let observed { return observed }
                    return intent ?? ""
                }
            }
        }
    }

    struct Agent: Codable, Identifiable {
        var id: String
        var domains: [String]?
        var busy: Bool
        var lastSeen: Date?

        enum CodingKeys: String, CodingKey {
            case id, domains, busy
            case lastSeen = "last_seen"
        }
    }

    /// One lane per domain. A held lane is work happening right now.
    struct Lock: Codable, Identifiable, Hashable {
        var domain: String
        var held: Bool
        var id: String { domain }
    }

    struct Budget: Codable {
        var spent: Double
        var limit: Double
        var fraction: Double?
        var periodStart: String?

        enum CodingKeys: String, CodingKey {
            case spent, limit, fraction
            case periodStart = "period_start"
        }
    }

    struct Persona: Codable {
        var key: String
        var label: String
        var tagline: String
    }

    static let empty = Office(
        now: nil, halted: false, inFlight: [], delegating: [], needsYou: [],
        queued: [], recent: [], findings: [],
        conversation: Conversation(id: nil, turns: []),
        agents: [], locks: [], budget: nil, island: nil, persona: nil)
}

struct DeviceCommand: Codable, Identifiable {
    var id: String
    var kind: String
    var payload: [String: AnyCodable]?
    var taskId: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, payload
        case taskId = "task_id"
    }
}

/// Minimal type-erased JSON value so a command payload can carry anything the
/// server puts in it without the app needing to know the shape in advance.
struct AnyCodable: Codable, Hashable {
    let value: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else if let b = try? c.decode(Bool.self) { value = String(b) }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

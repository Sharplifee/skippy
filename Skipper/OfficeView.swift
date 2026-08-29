import SwiftUI

@MainActor
final class OfficeStore: ObservableObject {
    @Published var office: Office = .empty
    @Published var error: String?
    @Published var loading = false
    @Published var draft = ""
    @Published var sending = false
    @Published var lastReply: String?

    /// Off by default. Flip it in Settings when you want Skipper to take the
    /// Island for a specific long job.
    @AppStorage("skipper.islandEnabled") var islandEnabled = false

    private var pump: Task<Void, Never>?

    func start() async {
        if await !SkipperAPI.shared.isRegistered {
            do { try await SkipperAPI.shared.register() }
            catch { self.error = error.localizedDescription }
        }
        await refresh()
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.refresh(silent: true)
            }
        }
    }

    func refresh(silent: Bool = false) async {
        if !silent { loading = true }
        defer { loading = false }
        do {
            let fresh = try await SkipperAPI.shared.office()
            office = fresh
            error = nil
            // The Live Activity is OPT-IN. It is never started automatically —
            // there is one Dynamic Island slot and another app usually owns it.
            // Status arrives as push alerts instead.
            if islandEnabled, let island = fresh.island {
                if island.phase == .done && island.runsActive == 0 && island.runsNeedingYou == 0 {
                    await ActivityController.shared.end()
                } else {
                    await ActivityController.shared.start(
                        conversationId: fresh.conversation.id ?? "", initial: island)
                    await ActivityController.shared.update(island)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sending = true
        defer { sending = false }
        do {
            let said = try await SkipperAPI.shared.say(text)
            lastReply = said.reply
            await refresh(silent: true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Walking into Skipper's office: every lane, every job, every answer, and the
/// conversation, on one screen.
struct OfficeView: View {
    @EnvironmentObject var store: OfficeStore
    @FocusState private var composing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    StatusHeader(office: store.office)
                        .padding(.top, 8)
                    LaneStrip(locks: store.office.locks)

                    if !store.office.needsYou.isEmpty {
                        Section("Needs you", tint: .orange) {
                            ForEach(store.office.needsYou) { item in
                                BlockedRow(item: item)
                            }
                        }
                    }
                    if !store.office.inFlight.isEmpty {
                        Section("Working now", tint: .blue) {
                            ForEach(store.office.inFlight) { t in RunningRow(task: t) }
                        }
                    }
                    if !store.office.delegating.isEmpty {
                        Section("Plans in progress", tint: .purple) {
                            ForEach(store.office.delegating) { d in PlanRow(plan: d) }
                        }
                    }
                    if !store.office.queued.isEmpty {
                        Section("Up next", tint: .secondary) {
                            ForEach(store.office.queued) { q in
                                Row(icon: "circle.dashed", title: q.intent, subtitle: q.domain)
                            }
                        }
                    }
                    if !store.office.findings.isEmpty {
                        Section("Answers", tint: .teal) {
                            ForEach(store.office.findings) { f in FindingRow(finding: f) }
                        }
                    }
                    if !store.office.recent.isEmpty {
                        Section("Finished", tint: .green) {
                            ForEach(store.office.recent) { r in CompletedRow(item: r) }
                        }
                    }
                    if !store.office.conversation.turns.isEmpty {
                        Section("Conversation", tint: .secondary) {
                            ForEach(store.office.conversation.turns) { t in TurnRow(turn: t) }
                        }
                    }
                    if let e = store.error {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 90)
            }
            .refreshable { await store.refresh() }
            .navigationTitle("Skipper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.bar, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { Composer(store: store, composing: $composing) }
        }
    }
}

// MARK: - Header

private struct StatusHeader: View {
    let office: Office

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let island = office.island {
                HStack(spacing: 10) {
                    Image(systemName: island.phase.glyph)
                        .font(.title3)
                        .foregroundStyle(tint(island.phase))
                        .symbolEffect(.pulse, isActive: island.phase == .working)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(island.phase.label).font(.headline)
                        Text(island.headline)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            if let b = office.budget {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(b.spent / max(b.limit, 0.01), 1))
                        .tint(b.spent / max(b.limit, 0.01) > 0.8 ? .orange : .accentColor)
                    Text(String(format: "$%.2f of $%.0f this period", b.spent, b.limit))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if office.halted == true {
                Label("Halted — nothing will run", systemImage: "pause.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.top, 4)
    }

    private func tint(_ p: SkipperAttributes.ContentState.Phase) -> Color {
        switch p {
        case .working: return .blue
        case .waiting: return .orange
        case .blocked, .outOfBudget: return .yellow
        case .failed: return .red
        case .done: return .green
        }
    }
}

/// Four lanes, one per domain. A lit lane is work happening right now — this is
/// the parallelism made visible.
private struct LaneStrip: View {
    let locks: [Office.Lock]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(locks) { lock in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(lock.held ? Color.accentColor : Color.secondary.opacity(0.18))
                        .frame(height: 5)
                    Text(lock.domain)
                        .font(.caption2)
                        .foregroundStyle(lock.held ? .primary : .secondary)
                }
            }
        }
    }
}

// MARK: - Rows

private struct Section<Content: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder let content: Content

    init(_ title: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(tint)
            content
        }
    }
}

private struct Row: View {
    var icon: String
    var title: String
    var subtitle: String?
    var detail: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).lineLimit(3)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RunningRow: View {
    let task: Office.Task
    var body: some View {
        Row(icon: "arrow.triangle.2.circlepath",
            title: task.intent,
            subtitle: [task.domain, task.agent, task.attempt.map { "attempt \($0)" }]
                .compactMap { $0 }.joined(separator: " · "),
            tint: .blue)
    }
}

private struct BlockedRow: View {
    let item: Office.Blocked
    var body: some View {
        Row(icon: "hand.raised.fill",
            title: item.intent,
            subtitle: "\(item.domain) · \(item.status)",
            detail: item.lastObserved ?? item.why,
            tint: .orange)
    }
}

private struct PlanRow: View {
    let plan: Office.Delegation
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Row(icon: "list.bullet.indent", title: plan.intent,
                subtitle: plan.plan, tint: .purple)
            ForEach(plan.children ?? [], id: \.self) { c in
                HStack(spacing: 7) {
                    Image(systemName: glyph(c.status))
                        .font(.caption2)
                        .foregroundStyle(c.status == "passed" ? .green : .secondary)
                    Text(c.intent).font(.caption).lineLimit(1)
                    Text(c.domain).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
            }
        }
    }

    private func glyph(_ s: String) -> String {
        switch s {
        case "passed":  return "checkmark.circle.fill"
        case "running", "verifying": return "circle.dotted"
        case "failed", "killed": return "xmark.circle.fill"
        default: return "circle"
        }
    }
}

private struct CompletedRow: View {
    let item: Office.Completed
    var body: some View {
        Row(icon: item.status == "passed" ? "checkmark.circle.fill" : "xmark.circle.fill",
            title: item.intent,
            subtitle: [item.domain, item.costUsd.map { String(format: "$%.4f", $0) }]
                .compactMap { $0 }.joined(separator: " · "),
            detail: item.observed,
            tint: item.status == "passed" ? .green : .red)
    }
}

private struct FindingRow: View {
    let finding: Office.Finding
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(finding.question).font(.caption).foregroundStyle(.secondary)
            Text(finding.answer).font(.subheadline)
            if let c = finding.confidence {
                Text(c).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TurnRow: View {
    let turn: Office.Conversation.Turn

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: turn.role == "user" ? "person.fill" : "sparkle")
                .font(.caption).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                if turn.content.kind == "plan", let steps = turn.content.steps {
                    Text(turn.content.note ?? "Plan").font(.subheadline)
                    ForEach(steps, id: \.self) { s in
                        Text("• \(s.intent) (\(s.domain))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(turn.content.display).font(.subheadline)
                    if let v = turn.content.verdict {
                        Text(v).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct Composer: View {
    @ObservedObject var store: OfficeStore
    @FocusState.Binding var composing: Bool

    var body: some View {
        HStack(spacing: 10) {
            if store.sending {
                ProgressView().scaleEffect(0.8).padding(.leading, 4)
            }
            TextField("Tell Skipper what to do", text: $store.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($composing)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())

            Button {
                composing = false
                Task { await store.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(store.sending || store.draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

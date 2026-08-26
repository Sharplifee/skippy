import WidgetKit
import SwiftUI
import ActivityKit

@main
struct SkippyWidgetBundle: WidgetBundle {
    var body: some Widget { SkippyLiveActivity() }
}

/// Every Dynamic Island surface plus the Lock Screen presentation. The server
/// pushes `ContentState` straight into these — no fetching happens here.
struct SkippyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SkippyAttributes.self) { context in
            LockScreenView(state: context.state, agent: context.attributes.agentName)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase.glyph)
                        .font(.title3)
                        .foregroundStyle(tint(context.state.phase))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if context.state.runsActive > 0 {
                            Text("\(context.state.runsActive)")
                                .font(.title3).monospacedDigit()
                            Text("running").font(.caption2).foregroundStyle(.secondary)
                        } else if context.state.runsNeedingYou > 0 {
                            Text("\(context.state.runsNeedingYou)")
                                .font(.title3).monospacedDigit().foregroundStyle(.orange)
                            Text("waiting").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.phase.label)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(context.state.headline)
                            .font(.subheadline).lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let f = context.state.budgetFraction, f > 0 {
                        VStack(spacing: 3) {
                            ProgressView(value: min(f, 1))
                                .tint(f > 0.8 ? .orange : .accentColor)
                            if let c = context.state.costToday {
                                Text(String(format: "$%.4f today", c))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase.glyph)
                    .foregroundStyle(tint(context.state.phase))
            } compactTrailing: {
                if context.state.phase == .outOfBudget, let f = context.state.budgetFraction {
                    Gauge(value: min(f, 1)) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(.orange)
                        .scaleEffect(0.6)
                } else if context.state.runsActive > 0 {
                    Text("\(context.state.runsActive)").monospacedDigit()
                } else if context.state.runsNeedingYou > 0 {
                    Text("\(context.state.runsNeedingYou)")
                        .monospacedDigit().foregroundStyle(.orange)
                }
            } minimal: {
                Image(systemName: context.state.phase.glyph)
                    .foregroundStyle(tint(context.state.phase))
            }
            .keylineTint(tint(context.state.phase))
        }
    }

    private func tint(_ p: SkippyAttributes.ContentState.Phase) -> Color {
        switch p {
        case .working: return .blue
        case .waiting: return .orange
        case .blocked, .outOfBudget: return .yellow
        case .failed: return .red
        case .done: return .green
        }
    }
}

private struct LockScreenView: View {
    let state: SkippyAttributes.ContentState
    let agent: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.phase.glyph)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(agent).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(state.phase.label).font(.caption).foregroundStyle(color)
                }
                Text(state.headline).font(.subheadline).lineLimit(2)

                HStack(spacing: 12) {
                    if state.runsActive > 0 {
                        Label("\(state.runsActive)", systemImage: "gearshape.2")
                            .font(.caption2)
                    }
                    if state.runsNeedingYou > 0 {
                        Label("\(state.runsNeedingYou)", systemImage: "hand.raised")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if let c = state.costToday, c > 0 {
                        Text(String(format: "$%.4f", c))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
    }

    private var color: Color {
        switch state.phase {
        case .working: return .blue
        case .waiting: return .orange
        case .blocked, .outOfBudget: return .yellow
        case .failed: return .red
        case .done: return .green
        }
    }
}

import SwiftUI
import UsageCore

struct PopoverView: View {
    @Bindable var model: UsageModel
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if model.providers.isEmpty {
                    Text(model.refreshing ? "Checking the sign-ins on this Mac…" : "No usage yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.providers.enumerated()), id: \.element.id) { index, provider in
                            if index > 0 {
                                Divider().padding(.leading, 14)
                            }
                            ProviderBlock(provider: provider)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack {
            Text("Usage")
                .font(.headline)
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.refreshing)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit", action: quit)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footerText: String {
        guard let updated = model.providers.map(\.updatedAt).max() else {
            return "This Mac only"
        }
        return updated.formatted(date: .omitted, time: .shortened)
    }
}

private struct ProviderBlock: View {
    var provider: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let plan = provider.plan {
                    Text(shortPlan(plan))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if provider.meters.isEmpty, let note = provider.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(provider.meters) { meter in
                        MeterCell(meter: meter)
                    }
                }
                if let note = provider.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func shortPlan(_ plan: String) -> String {
        let lower = plan.lowercased()
        if lower.contains("ultra") { return "Ultra" }
        return plan
    }
}

private struct MeterCell: View {
    var meter: Meter

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(primary)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primary: String {
        if let percent = meter.remainingPercent {
            return "\(percent)%"
        }
        return meter.detail.split(separator: " ").first.map(String.init) ?? meter.detail
    }

    private var caption: String {
        let label = shortLabel(meter.label)
        guard meter.remaining != nil else { return label }
        let when = shortWhen(meter.detail)
        return when.isEmpty ? label : "\(label) · \(when)"
    }

    private var color: Color {
        guard let remaining = meter.remaining else { return .primary }
        if remaining <= 0.15 { return .red }
        if remaining <= 0.4 { return .orange }
        return .green
    }

    private func shortLabel(_ label: String) -> String {
        switch label {
        case "Session": "5h"
        case "Weekly": "Week"
        case "Claude / GPT": "C/GPT"
        default: label
        }
    }

    private func shortWhen(_ detail: String) -> String {
        let stripped = detail
            .replacingOccurrences(of: "resets in ", with: "")
            .replacingOccurrences(of: "cycle ends in ", with: "")
        guard stripped != detail else { return detail == "resets now" ? "now" : "" }
        return stripped.split(separator: " ").first.map(String.init) ?? stripped
    }
}

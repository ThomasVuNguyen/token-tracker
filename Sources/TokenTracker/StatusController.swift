import AppKit
import SwiftUI
import UsageCore

@MainActor
final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = UsageModel()
    private var timer: Timer?

    func start() {
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Usage")
            button.imagePosition = .imageLeading
            button.action = #selector(toggle)
            button.target = self
        }
        popover.behavior = .transient
        let host = NSHostingController(rootView: PopoverView(model: model) { [weak self] in
            NSApp.terminate(nil)
            _ = self
        })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        updateTitle()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        fitPopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        Task { await refresh() }
    }

    private func refresh() async {
        await model.refresh()
        updateTitle()
        fitPopover()
    }

    private func fitPopover() {
        guard let host = popover.contentViewController else { return }
        host.view.layoutSubtreeIfNeeded()
        let height = host.view.fittingSize.height
        guard height > 1 else { return }
        popover.contentSize = NSSize(width: 300, height: height)
    }

    private func updateTitle() {
        guard let button = item.button else { return }
        let tightest = model.providers.compactMap { provider -> (ProviderSnapshot, Meter)? in
            let meters = provider.meters.filter { $0.remaining != nil }
            guard let meter = meters.min(by: { ($0.remaining ?? 1) < ($1.remaining ?? 1) }) else { return nil }
            return (provider, meter)
        }.min { ($0.1.remaining ?? 1) < ($1.1.remaining ?? 1) }

        if let tightest, let percent = tightest.1.remainingPercent {
            button.title = " \(tightest.0.menuLabel) \(percent)%"
        } else if model.providers.isEmpty {
            button.title = " Usage"
        } else {
            button.title = " Usage"
        }
    }
}

@MainActor
@Observable
final class UsageModel {
    var providers: [ProviderSnapshot] = []
    var refreshing = false
    private var generation = 0

    func refresh() async {
        generation += 1
        let generation = generation
        refreshing = true
        let incoming = await UsageTracker().refresh()
        guard generation == self.generation else { return }
        providers = providers.isEmpty ? incoming : merge(previous: providers, incoming: incoming)
        refreshing = false
    }

    private func merge(previous: [ProviderSnapshot], incoming: [ProviderSnapshot]) -> [ProviderSnapshot] {
        incoming.map { next in
            guard next.meters.isEmpty,
                  let prior = previous.first(where: { $0.id == next.id }),
                  !prior.meters.isEmpty else { return next }
            var kept = prior
            kept.note = next.note
            kept.updatedAt = next.updatedAt
            return kept
        }
    }
}

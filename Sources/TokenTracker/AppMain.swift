import AppKit
import ServiceManagement
import UsageCore

@main
enum TokenTrackerMain {
    static func main() {
        if CommandLine.arguments.contains("--check") {
            do {
                try FixtureCheck.assertParsers()
            } catch {
                fputs("\(error)\n", stderr)
                exit(1)
            }
            return
        }

        if CommandLine.arguments.contains("--once") {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                let snapshots = await UsageTracker().refresh()
                print(snapshots.map(\.summary).joined(separator: "\n\n"))
                semaphore.signal()
            }
            semaphore.wait()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = StatusControllerBox()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let controller = controller
        Task { @MainActor in
            controller.start()
        }
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}

final class StatusControllerBox: @unchecked Sendable {
    private var controller: StatusController?

    @MainActor func start() {
        let controller = StatusController()
        controller.start()
        self.controller = controller
    }
}

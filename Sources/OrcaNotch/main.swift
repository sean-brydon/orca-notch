import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var demo: DemoDirector?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-record"), i + 1 < args.count {
            demo = DemoDirector(recordTo: URL(fileURLWithPath: args[i + 1]))
            demo?.start()
        } else if args.contains("--demo") {
            demo = DemoDirector(recordTo: nil)
            demo?.start()
        } else {
            controller = NotchController()
            controller?.start()
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

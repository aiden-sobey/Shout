import AppKit
import ShoutCore

if CommandLine.arguments.contains("--self-test") {
    Task { @MainActor in
        exit(await SelfTest.run(arguments: CommandLine.arguments))
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.run()
}

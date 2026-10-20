import AppKit
import Foundation

/// Quit and start this same build again.
///
/// A small shell waits until this process is gone before `open` runs. With the
/// old one still alive, `open` would only bring its windows forward, and a
/// Screen Recording grant — or a settings file just imported — would stay
/// invisible to it.
enum AppRelaunch {

    private static let log = FileLog("Relaunch")

    static func relaunch(arguments: [String]) {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { relaunch(arguments: arguments) }
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $1 is the pid, $2 is this bundle. `shift 2` leaves the arguments the
        // new process should see, each as its own word, so a value with a space
        // is not split.
        task.arguments = [
            "-c",
            "pid=\"$1\"; app=\"$2\"; shift 2; while kill -0 \"$pid\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open -n \"$app\" --args \"$@\"",
            "sh", "\(pid)", Bundle.main.bundlePath,
        ] + arguments
        do {
            try task.run()
        } catch {
            log.error("relaunch helper failed to start: \(error.localizedDescription)")
            return
        }
        log.info("relaunching")
        NSApp.terminate(nil)
    }
}

import AppKit
import Foundation

/// Quit and start this same build again.
///
/// A small shell waits until this process is gone before `open` runs. With the
/// old one still alive, `open` would only bring its windows forward, and a
/// Screen Recording grant — or a settings file just imported — would stay
/// invisible to it.
///
/// `NSApp.terminate` does nothing at all while a window has a sheet attached:
/// it returns at once, and the delegate is never asked. The backup import's
/// Restart Now button sits in a sheet, so every open sheet is closed first, and
/// the quit is asked for again until it goes through.
///
/// The shell is started only from `willTerminate`, once quitting is certain.
/// Started earlier, a quit that does not happen would leave it waiting, and
/// every further click would add another, each opening its own copy when the
/// app finally exits.
enum AppRelaunch {

    private static let log = FileLog("Relaunch")

    /// The arguments for the new process, set once a relaunch is asked for.
    private static var pendingArguments: [String]?
    private static var observer: NSObjectProtocol?

    static func relaunch(arguments: [String]) {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { relaunch(arguments: arguments) }
            return
        }
        pendingArguments = arguments
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                    startHelper()
                }
        }
        log.info("relaunching")
        quit(triesLeft: 50)
    }

    /// `endSheet` only starts the sheet's closing animation, so the sheet can
    /// still be attached on the next pass and the quit ignored again. A quit
    /// that goes through never returns: `terminate` ends the process. Getting
    /// past it means it was refused, so try again shortly, for up to ~5 s.
    private static func quit(triesLeft: Int) {
        closeSheets()
        if NSApp.windows.contains(where: { $0.attachedSheet != nil }) && triesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { quit(triesLeft: triesLeft - 1) }
            return
        }
        NSApp.terminate(nil)
        guard triesLeft > 0 else {
            log.error("quit was refused; not relaunching")
            pendingArguments = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { quit(triesLeft: triesLeft - 1) }
    }

    /// Ends every attached sheet, a sheet's own sheet first.
    private static func closeSheets() {
        for _ in 0..<8 {
            let open = NSApp.windows.compactMap { window in window.attachedSheet.map { (window, $0) } }
            guard !open.isEmpty else { return }
            for (window, sheet) in open where sheet.attachedSheet == nil {
                window.endSheet(sheet)
            }
        }
    }

    private static func startHelper() {
        guard let arguments = pendingArguments else { return }
        pendingArguments = nil
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
        }
    }
}

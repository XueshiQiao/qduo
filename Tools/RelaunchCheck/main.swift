import AppKit
import SwiftUI
// Checks AppRelaunch the way the backup import uses it: a SwiftUI sheet is up
// and Restart Now is clicked three times. Run by scripts/check-relaunch.sh.
// The first launch writes "first <pid>" to the marker file and asks for a
// relaunch three times; each relaunched copy appends "relaunched <pid>" and quits.
let args = CommandLine.arguments
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        if args.contains("--relaunched") {
            let line = "relaunched \(ProcessInfo.processInfo.processIdentifier)\n"
            let path = args[args.firstIndex(of: "--marker")! + 1]
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
            exit(0)
        }
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Root())
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let path = args[args.firstIndex(of: "--marker")! + 1]
            try? "first \(ProcessInfo.processInfo.processIdentifier) sheet=\(self.window.attachedSheet != nil)\n".write(toFile: path, atomically: true, encoding: .utf8)
            for _ in 0..<3 { AppRelaunch.relaunch(arguments: ["--relaunched", "--marker", path]) }
        }
    }
}
struct Root: View {
    @State var show = true
    var body: some View { Text("main").frame(width: 300, height: 200).sheet(isPresented: $show) { Text("sheet").frame(width: 200, height: 100) } }
}
let app = NSApplication.shared
let d = Delegate(); app.delegate = d
app.run()

import Darwin
import Foundation

/// Runs the production inbox socket + ScriptInbox with no app, playback or provider.
@main enum LocalScriptInboxSocketProbe {
    @MainActor static var inbox = ScriptInbox()

    static func main() {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/private/tmp/cbtts-inbox-") else {
            fputs("Invalid probe arguments\n", stderr); exit(2)
        }
        let listener = LocalScriptInboxSocket(directory: CommandLine.arguments[1]) { submission in
            inbox.submit(displayText: submission.displayText, speechText: submission.speechText,
                         key: submission.key, now: Date()).rawValue
        }
        guard listener.start() else { print("socket-unavailable"); exit(3) }
        print("ready"); fflush(stdout)
        // Commands arrive on a background thread; the handler itself runs on the main queue.
        Thread.detachNewThread {
            while let command = readLine() {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        switch command {
                        case "state": print("\(inbox.items.count) items")
                        case "dump":
                            let rows = inbox.items.map { [$0.displayText, $0.speechText, $0.key] }
                            print(String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
                        case "off": listener.stop(); print("off")
                        default: print("unknown")
                        }
                        fflush(stdout)
                    }
                }
            }
            exit(0)
        }
        dispatchMain()
    }
}

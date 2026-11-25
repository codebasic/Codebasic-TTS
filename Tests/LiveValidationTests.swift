import Foundation
@main struct LiveValidationTests {
    static func main() throws {
        precondition(V2Runtime.liveValidation && !V2Runtime.offline && V2Runtime.suppressDiscovery)
        precondition(V2Runtime.dataRoot.hasPrefix("/private/tmp/") || V2Runtime.dataRoot.hasPrefix("/tmp/"))
        precondition(V2Runtime.consumeLivePermit("google"))
        precondition(!V2Runtime.consumeLivePermit("google"))
        precondition(V2Runtime.consumeLivePermit("elevenlabs"))
        precondition(!V2Runtime.consumeLivePermit("elevenlabs"))
        precondition(!V2Runtime.consumeLivePermit("other-provider"))
        V2Runtime.recordLiveEvidence("google-usage", ["synthetic": true])
        precondition(FileManager.default.fileExists(atPath: V2Runtime.dataRoot + "/live-google-usage.json"))
        print("PASS: live validation isolates data, suppresses discovery and permits exactly one request per authorized provider; no network calls")
    }
}

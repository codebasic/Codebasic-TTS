import CryptoKit
import Darwin
import Foundation
import Security

enum AgentPeerSigning {
    static let appID = "com.seongjoo.SelectedTextTTS"
    static let helperID = "com.seongjoo.SelectedTextTTS.agent-helper"
    static let pinEnvironment = "CODEBASIC_TTS_SIGNER_SHA1"

    static func ownLeaf() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { return nil }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func bundledHelperHash() -> Data? {
        signedHash(at: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodebasicAgentMCP"))
    }

    static func signedHash(at url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return signedHash(code)
    }

    static func matches(pid: pid_t, identifier: String, leaf: String, expectedHash: Data) -> Bool {
        check([kSecGuestAttributePid as String: NSNumber(value: pid)], identifier: identifier, leaf: leaf,
              expectedHash: expectedHash)
    }

    static func matches(socket fd: Int32, identifier: String, leaf: String, expectedHash: Data? = nil) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        var token = audit_token_t()
        var count = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &count) == 0,
              count == MemoryLayout<audit_token_t>.size else { return false }
        return check([kSecGuestAttributeAudit as String: Data(bytes: &token, count: Int(count))],
                     identifier: identifier, leaf: leaf, expectedHash: expectedHash)
    }

    private static func signedHash(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }

    private static func check(_ attributes: [String: Any], identifier: String, leaf: String, expectedHash: Data?) -> Bool {
        guard identifier == appID || identifier == helperID,
              leaf.utf8.count == 40, leaf.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return false
        }
        let expression = "identifier \"\(identifier)\" and certificate leaf = H\"\(leaf)\""
        var requirement: SecRequirement?
        var guest: SecCode?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest) == errSecSuccess,
              let guest else { return false }
        guard SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else { return false }
        guard let expectedHash else { return true }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code else { return false }
        return signedHash(code) == expectedHash
    }
}

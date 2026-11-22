import CryptoKit
import Darwin
import Foundation
import Security

/// Entitlement-free macOS peer verification using `getpeereid`, `LOCAL_PEERPID`,
/// `LOCAL_PEERTOKEN` (`audit_token_t`), and `Security.framework` code signing checks.
enum AgentPeerVerifier {
    static let appSigningIdentifier = "com.seongjoo.SelectedTextTTS"
    static let helperSigningIdentifier = "com.seongjoo.SelectedTextTTS.agent-mcp"
    private static let peerTokenSize = 8 * MemoryLayout<UInt32>.size

    struct SigningIdentity: Equatable {
        let identifier: String
        let leafCertSHA1: String
        let cdHashHex: String
        let isAdhoc: Bool
    }

    static func ownSigningIdentity() -> SigningIdentity? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let code = selfCode else {
            return nil
        }
        return signingIdentity(of: code)
    }

    static func verifyConnectedHelper(
        fd: Int32,
        expectedIdentifier: String = helperSigningIdentifier,
        expectedLeafSHA1: String? = nil
    ) -> HelperPrincipal? {
        guard let leafSHA1 = expectedLeafSHA1 ?? ownSigningIdentity().flatMap({ $0.isAdhoc ? nil : $0.leafCertSHA1 }),
              isValidHexSHA1(leafSHA1) else {
            return nil
        }
        return verifyConnectedPeer(
            fd: fd,
            expectedIdentifier: expectedIdentifier,
            expectedLeafSHA1: leafSHA1.lowercased()
        )
    }

    static func verifyConnectedApp(
        fd: Int32,
        expectedIdentifier: String = appSigningIdentifier,
        expectedLeafSHA1: String
    ) -> HelperPrincipal? {
        guard isValidHexSHA1(expectedLeafSHA1) else { return nil }
        return verifyConnectedPeer(
            fd: fd,
            expectedIdentifier: expectedIdentifier,
            expectedLeafSHA1: expectedLeafSHA1.lowercased()
        )
    }

    static func verifyConnectedPeer(
        fd: Int32,
        expectedIdentifier: String,
        expectedLeafSHA1: String
    ) -> HelperPrincipal? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              let peer = LocalInstructionPeer.connected(fd) else {
            return nil
        }

        var tokenBytes = [UInt8](repeating: 0, count: peerTokenSize)
        var tokenLen = socklen_t(peerTokenSize)
        let rc = tokenBytes.withUnsafeMutableBytes { buf in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, buf.baseAddress, &tokenLen)
        }
        guard rc == 0,
              Int(tokenLen) == peerTokenSize,
              tokenBytes.contains(where: { $0 != 0 }) else {
            return nil
        }

        let tokenData = Data(tokenBytes) as CFData
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &guestCode) == errSecSuccess,
              let code = guestCode else {
            return nil
        }

        let reqString = "identifier \"\(expectedIdentifier)\" and certificate leaf = H\"\(expectedLeafSHA1.lowercased())\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqString, [], &requirement) == errSecSuccess,
              let req = requirement,
              SecCodeCheckValidity(code, [], req) == errSecSuccess,
              let identity = signingIdentity(of: code),
              !identity.isAdhoc,
              identity.identifier == expectedIdentifier,
              identity.leafCertSHA1.lowercased() == expectedLeafSHA1.lowercased(),
              !identity.cdHashHex.isEmpty else {
            return nil
        }

        return HelperPrincipal(
            uid: uid,
            pid: peer.pid,
            startSeconds: peer.startSeconds,
            startMicroseconds: peer.startMicroseconds,
            signingIdentifier: identity.identifier,
            leafCertSHA1: identity.leafCertSHA1.lowercased(),
            cdHashHex: identity.cdHashHex
        )
    }

    static func isValidHexSHA1(_ s: String) -> Bool {
        s.utf8.count == 40 && s.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func signingIdentity(of code: SecCode) -> SigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let sCode = staticCode else {
            return nil
        }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(sCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            return nil
        }
        let identifier = info[kSecCodeInfoIdentifier as String] as? String ?? ""
        let rawFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdhoc = (rawFlags & SecCodeSignatureFlags.adhoc.rawValue) != 0
        guard let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else {
            return nil
        }
        let certData = SecCertificateCopyData(leaf) as Data
        let leafSHA1 = Insecure.SHA1.hash(data: certData)
            .map { String(format: "%02x", $0) }
            .joined()
        let cdHashData = info[kSecCodeInfoUnique as String] as? Data ?? Data()
        let cdHashHex = cdHashData.map { String(format: "%02x", $0) }.joined()
        return SigningIdentity(
            identifier: identifier,
            leafCertSHA1: leafSHA1,
            cdHashHex: cdHashHex,
            isAdhoc: isAdhoc
        )
    }
}

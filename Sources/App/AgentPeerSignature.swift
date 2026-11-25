// AgentPeerSignature.swift
// Shared by the app and by the signed agent bridge helper (Integrations/AgentBridge/main.swift).
//
// Security model (existing baseline, deliberately not extended):
//   * The ONLY security decision is verifyConnectedPeer / verify(peer:...): the kernel audit token of the
//     live peer of a connected AF_UNIX socket is resolved to its running code object and checked against
//     the requirement: exact signing identifier AND exact leaf certificate SHA-1 pin.
//   * Ad hoc or unsigned code has no leaf certificate and therefore can never satisfy the requirement.
//   * No CA anchor is invented, no Keychain item or secret is read, nothing is stored.
//   * informationalSigner(pid:) is racy by nature (PID reuse) and must only feed UI text.

import CryptoKit
import Darwin
import Foundation
import Security

enum AgentPeerSignature {
    static let bridgeIdentifier = "com.codebasic.tts.agent-bridge"
    /// Fixed signing identifier of the app. Compiled in; never read from the environment or a file.
    static let appIdentifier = "com.seongjoo.SelectedTextTTS"

    // <sys/un.h>: #define SOL_LOCAL 0, #define LOCAL_PEERTOKEN 0x006 (audit_token_t = 8 x UInt32).
    private static let solLocal: Int32 = 0
    private static let localPeerToken: Int32 = 0x006

    struct Peer {
        let auditToken: Data
        let pid: pid_t
        let effectiveUID: uid_t
        let realUID: uid_t
        let pidVersion: UInt32
    }

    struct SignerInfo {
        let identifier: String?
        let leafSHA1: String?
        let currentlyValid: Bool
    }

    private static func isHex(_ c: UInt8) -> Bool {
        switch c {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
        default: return false
        }
    }

    private static func isIdentifierByte(_ c: UInt8) -> Bool {
        switch c {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F: return true
        default: return false
        }
    }

    /// Strict identifier alphabet; also guarantees the value cannot alter the requirement text.
    static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 1, bytes.count <= 255 else { return false }
        return bytes.allSatisfy(isIdentifierByte)
    }

    /// Exactly 40 hex digits, returned upper-case. Anything else is rejected.
    static func normalizedSHA1(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard bytes.count == 40, bytes.allSatisfy(isHex) else { return nil }
        return value.uppercased()
    }

    /// Reads the kernel audit token of the peer of a connected AF_UNIX socket.
    static func peer(ofConnectedSocket fd: Int32) -> Peer? {
        var words = [UInt32](repeating: 0, count: 8)
        var length = socklen_t(MemoryLayout<UInt32>.size * 8)
        let rc = words.withUnsafeMutableBytes { raw -> Int32 in
            getsockopt(fd, solLocal, localPeerToken, raw.baseAddress, &length)
        }
        guard rc == 0, Int(length) == MemoryLayout<UInt32>.size * 8 else { return nil }
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0, euid == words[1] else { return nil }
        let pid = pid_t(bitPattern: words[5])
        guard pid > 0 else { return nil }
        let token = words.withUnsafeBytes { Data($0) }
        return Peer(auditToken: token, pid: pid, effectiveUID: words[1], realUID: words[3], pidVersion: words[7])
    }

    /// Live check of the running peer: exact identifier and pinned leaf certificate. Fails closed.
    static func verify(peer: Peer, identifier: String, leafSHA1: String) -> Bool {
        guard isValidIdentifier(identifier), let pin = normalizedSHA1(leafSHA1) else { return false }
        let attributes = [kSecGuestAttributeAudit as String: peer.auditToken as NSData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let code = guest else {
            return false
        }
        let text = "identifier \"\(identifier)\" and certificate leaf = H\"\(pin)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    /// The security decision for a connected socket: same UID (effective and real), not ourselves,
    /// and a live signature that satisfies identifier + pinned leaf certificate.
    static func verifyConnectedPeer(fd: Int32, expectedUID: uid_t, identifier: String, leafSHA1: String) -> Peer? {
        guard let found = peer(ofConnectedSocket: fd) else { return nil }
        guard found.effectiveUID == expectedUID, found.realUID == expectedUID, found.pid != getpid() else { return nil }
        guard verify(peer: found, identifier: identifier, leafSHA1: leafSHA1) else { return nil }
        return found
    }

    private static func sha1Hex(_ data: Data) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out = [UInt8]()
        for byte in Insecure.SHA1.hash(data: data) {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func signer(of code: SecCode, currentlyValid: Bool) -> SignerInfo? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let sc = staticCode else { return nil }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any] else { return nil }
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        var leaf: String?
        if let first = certificates?.first {
            leaf = sha1Hex(SecCertificateCopyData(first) as Data)
        }
        return SignerInfo(identifier: identifier, leafSHA1: leaf, currentlyValid: currentlyValid)
    }

    /// Public leaf certificate SHA-1 of this process's own, currently valid signature.
    /// Returns nil for unsigned, invalid or ad hoc code. Reads only public signing information.
    static func ownSignerSHA1() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let code = me else { return nil }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        guard let info = signer(of: code, currentlyValid: true) else { return nil }
        return info.leafSHA1
    }

    /// Signing identifier of this process's own, currently valid signature. Public information only.
    static func ownSigningIdentifier() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let code = me else { return nil }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        return signer(of: code, currentlyValid: true)?.identifier
    }

    /// INFORMATIONAL ONLY (UI text when the owner selects a PID). Never use for a trust decision:
    /// a PID can be reused; only verifyConnectedPeer on the live socket decides.
    static func informationalSigner(pid: pid_t) -> SignerInfo? {
        guard pid > 0 else { return nil }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let code = guest else {
            return nil
        }
        let valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        return signer(of: code, currentlyValid: valid)
    }
}

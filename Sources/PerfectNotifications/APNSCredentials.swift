import Crypto
import Foundation

/// Holds an APNs `.p8` private key and mints JWT provider tokens.
///
/// Apple accepts a provider token for up to 60 minutes, and refuses updates more often
/// than once every 20 minutes (`TooManyProviderTokenUpdates`). So a token is reused for
/// 50 minutes, is replaced early only after APNs rejected it, and is never replaced
/// within 20 minutes of being minted.
final class APNSCredentials: @unchecked Sendable {
    /// Proactive refresh age, safely inside Apple's 60-minute limit.
    static let refreshAge: TimeInterval = 50 * 60
    /// Apple's minimum interval between token updates.
    static let minimumRefreshInterval: TimeInterval = 20 * 60

    let keyID: String
    let teamID: String
    private let privateKey: P256.Signing.PrivateKey
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var cachedToken: String?
    private var issuedAt: Date = .distantPast
    private var rejected = false

    // MARK: Init

    convenience init(keyID: String, teamID: String, privateKeyPath: String) throws {
        let pem = try String(contentsOfFile: privateKeyPath, encoding: .utf8)
        try self.init(keyID: keyID, teamID: teamID, pemString: pem)
    }

    convenience init(keyID: String, teamID: String, pemString: String) throws {
        // Validate the IDs before parsing the key, so a bad ID is reported as such.
        try Self.validate(keyID: keyID, teamID: teamID)
        try self.init(keyID: keyID, teamID: teamID,
                      key: P256.Signing.PrivateKey(pemRepresentation: pemString))
    }

    init(keyID: String, teamID: String, key: P256.Signing.PrivateKey,
         now: @escaping @Sendable () -> Date = { Date() }) throws {
        try Self.validate(keyID: keyID, teamID: teamID)
        self.keyID = keyID
        self.teamID = teamID
        self.privateKey = key
        self.now = now
    }

    private static func validate(keyID: String, teamID: String) throws(APNSClientError) {
        guard APNSValidation.isTenCharacterID(keyID) else { throw .invalidKeyID }
        guard APNSValidation.isTenCharacterID(teamID) else { throw .invalidTeamID }
    }

    // MARK: Token vending

    /// Returns the cached JWT, or mints a new one when the cached one is 50 minutes old,
    /// or was rejected by APNs and is at least 20 minutes old.
    func token() throws -> String {
        try lock.withLock {
            let current = now()
            if let cached = cachedToken {
                let age = current.timeIntervalSince(issuedAt)
                if age < Self.minimumRefreshInterval { return cached }
                if age < Self.refreshAge && !rejected { return cached }
            }
            let token = try makeJWT(issuedAt: current)
            cachedToken = token
            issuedAt = current
            rejected = false
            return token
        }
    }

    /// Records that APNs rejected `token` (`ExpiredProviderToken` or `InvalidProviderToken`).
    ///
    /// - Returns: `true` if the next ``token()`` call will return a different token, either
    ///   because one has already replaced `token` or because a new one may be minted now.
    func reject(_ token: String) -> Bool {
        lock.withLock {
            guard token == cachedToken else { return true }
            rejected = true
            return now().timeIntervalSince(issuedAt) >= Self.minimumRefreshInterval
        }
    }

    // MARK: JWT minting

    private struct Header: Encodable { let alg: String; let kid: String }
    private struct Claims: Encodable { let iss: String; let iat: Int }

    private func makeJWT(issuedAt: Date) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(Header(alg: "ES256", kid: keyID))
        let claims = try encoder.encode(Claims(iss: teamID, iat: Int(issuedAt.timeIntervalSince1970)))
        let signingInput = base64URL(header) + "." + base64URL(claims)
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }
}

// MARK: - Redaction

extension APNSCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "APNSCredentials(keyID: \(keyID), teamID: \(teamID), key: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["keyID": keyID, "teamID": teamID, "key": "<redacted>"],
               displayStyle: .class)
    }
}

// MARK: - Base64URL (no padding, URL-safe alphabet)

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

import Crypto
import Foundation

/// Holds an APNs `.p8` private key, mints JWT provider tokens, and rotates them
/// automatically before the 60-minute APNs expiry.
final class APNSCredentials: @unchecked Sendable {
    private let keyID: String
    private let teamID: String
    private let privateKey: P256.Signing.PrivateKey

    private let lock = NSLock()
    private var cachedToken: String?
    private var tokenIssuedAt: Date = .distantPast

    // MARK: Init

    init(keyID: String, teamID: String, privateKeyPath: String) throws {
        self.keyID = keyID
        self.teamID = teamID
        let pem = try String(contentsOfFile: privateKeyPath, encoding: .utf8)
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    init(keyID: String, teamID: String, pemString: String) throws {
        self.keyID = keyID
        self.teamID = teamID
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: pemString)
    }

    init(keyID: String, teamID: String, key: P256.Signing.PrivateKey) {
        self.keyID = keyID
        self.teamID = teamID
        self.privateKey = key
    }

    // MARK: Token vending

    /// Returns a valid JWT, reusing the cached token if it is less than 55 minutes old.
    func token() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(tokenIssuedAt) < 55 * 60, let cached = cachedToken {
            return cached
        }
        let token = try makeJWT()
        cachedToken = token
        tokenIssuedAt = Date()
        return token
    }

    // MARK: JWT minting

    private func makeJWT() throws -> String {
        let iat = Int(Date().timeIntervalSince1970)
        let headerJSON  = "{\"alg\":\"ES256\",\"kid\":\"\(keyID)\"}"
        let payloadJSON = "{\"iss\":\"\(teamID)\",\"iat\":\(iat)}"

        let signingInput = b64url(headerJSON) + "." + b64url(payloadJSON)
        let hash = SHA256.hash(data: Data(signingInput.utf8))
        let sig  = try privateKey.signature(for: hash)
        return signingInput + "." + b64urlData(sig.rawRepresentation)
    }
}

// MARK: - Base64URL helpers (no padding, URL-safe alphabet)

private func b64url(_ string: String) -> String {
    b64urlData(Data(string.utf8))
}

private func b64urlData(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CryptoKit
import Foundation

/// RFC 9449 proof key. Only the public JWK leaves this device; the private
/// representation is saved using the existing device-only Keychain store.
struct T3DPoPKey: Sendable {
    enum Failure: Error { case invalidKey, invalidURL }
    private let bytes: Data

    init() { bytes = P256.Signing.PrivateKey().rawRepresentation }

    init(stored: String) throws {
        guard let bytes = Data(base64Encoded: stored),
              (try? P256.Signing.PrivateKey(rawRepresentation: bytes)) != nil else { throw Failure.invalidKey }
        self.bytes = bytes
    }

    var stored: String { bytes.base64EncodedString() }

    var publicJWK: [String: String] {
        let key = try! P256.Signing.PrivateKey(rawRepresentation: bytes).publicKey.x963Representation
        return ["kty": "EC", "crv": "P-256", "x": Self.base64URL(key[1..<33]), "y": Self.base64URL(key[33..<65])]
    }

    var thumbprint: String {
        Self.base64URL(SHA256.hash(data: Self.json(publicJWK)))
    }

    func proof(method: String, url: URL, accessToken: String? = nil, now: Date = Date(),
               identifier: String = UUID().uuidString) throws -> String {
        guard var target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              target.scheme == "https" || target.scheme == "http", target.host != nil,
              target.user == nil, target.password == nil else { throw Failure.invalidURL }
        target.query = nil
        target.fragment = nil
        target.scheme = target.scheme?.lowercased()
        target.host = target.host?.lowercased()
        if (target.scheme == "https" && target.port == 443) || (target.scheme == "http" && target.port == 80) { target.port = nil }
        if target.path.isEmpty { target.path = "/" }
        guard let htu = target.url?.absoluteString else { throw Failure.invalidURL }
        let header: [String: Any] = ["typ": "dpop+jwt", "alg": "ES256", "jwk": publicJWK]
        var payload: [String: Any] = ["htm": method.uppercased(), "htu": htu,
                                      "iat": Int(now.timeIntervalSince1970), "jti": identifier]
        if let accessToken { payload["ath"] = Self.base64URL(SHA256.hash(data: Data(accessToken.utf8))) }
        let signingInput = Self.base64URL(Self.json(header)) + "." + Self.base64URL(Self.json(payload))
        let key = try P256.Signing.PrivateKey(rawRepresentation: bytes)
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + Self.base64URL(signature)
    }

    func authorize(_ request: inout URLRequest, token: String) throws {
        guard let url = request.url else { throw Failure.invalidURL }
        request.setValue("DPoP \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(try proof(method: request.httpMethod ?? "GET", url: url, accessToken: token), forHTTPHeaderField: "DPoP")
    }

    static func base64URL<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

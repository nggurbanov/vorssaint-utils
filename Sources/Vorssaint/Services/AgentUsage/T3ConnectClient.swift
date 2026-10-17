// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum T3ConnectError: Error, Equatable {
    case unavailable, invalidResponse, signInRequired, declined, expired
    case unsupported, keychainUnavailable, environmentMismatch
}

struct T3ConnectConfiguration: Sendable {
    let issuer: URL
    let relay: URL
    let oauthClientID: String
    // Public protocol identifiers published in T3 v0.1.0's .env.example.
    // The relay currently accepts only the t3-web and t3-mobile client types.
    static let production = T3ConnectConfiguration(issuer: URL(string: "https://clerk.t3.codes")!,
        relay: URL(string: "https://relay.t3.codes")!, oauthClientID: "hzxSgY2cH10sDU2r")
}

struct T3ConnectOAuthMetadata: Decodable {
    let issuer: String
    let token_endpoint: String
    let device_authorization_endpoint: String?
    let userinfo_endpoint: String
    let revocation_endpoint: String?
}

struct T3ConnectDeviceChallenge: Decodable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let verification_uri_complete: String?
    let expires_in: Double
    let interval: Double?
}

struct T3ConnectCloudTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

enum T3ConnectDevicePoll {
    case pending, slowDown
    case authorized(T3ConnectCloudTokens)
}

struct T3ConnectIdentity: Decodable {
    let sub: String
    let name: String?
    let email: String?
    var label: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? email ?? sub }
}

struct T3ConnectEnvironment: Decodable, Equatable, Identifiable {
    struct Endpoint: Decodable, Equatable {
        let httpBaseUrl: String
    }
    let environmentId: String
    let label: String
    let endpoint: Endpoint
    var id: String { environmentId }
}

/// Independent OAuth authorization and relay access. Cloud access tokens never
/// go to environments; only a one-time, proof-bound bootstrap does.
struct T3ConnectClient {
    let configuration: T3ConnectConfiguration
    let transport: T3CodeHTTPTransport

    init(configuration: T3ConnectConfiguration = .production,
         transport: T3CodeHTTPTransport = T3URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    func metadata() async throws -> T3ConnectOAuthMetadata {
        let data = try await success(request(configuration.issuer.appendingPathComponent(".well-known/openid-configuration")))
        guard let metadata = try? JSONDecoder().decode(T3ConnectOAuthMetadata.self, from: data),
              metadata.issuer == configuration.issuer.absoluteString else { throw T3ConnectError.invalidResponse }
        _ = try issuerEndpoint(metadata.token_endpoint)
        _ = try issuerEndpoint(metadata.userinfo_endpoint)
        if let endpoint = metadata.revocation_endpoint { _ = try issuerEndpoint(endpoint) }
        return metadata
    }

    func beginDeviceAuthorization(metadata: T3ConnectOAuthMetadata) async throws -> T3ConnectDeviceChallenge {
        guard let endpoint = metadata.device_authorization_endpoint else { throw T3ConnectError.unsupported }
        let data = try await success(request(try issuerEndpoint(endpoint), form: [
            "client_id": configuration.oauthClientID, "scope": "openid profile email offline_access"
        ]))
        guard let challenge = try? JSONDecoder().decode(T3ConnectDeviceChallenge.self, from: data),
              !challenge.device_code.isEmpty, !challenge.user_code.isEmpty,
              challenge.expires_in.isFinite, (1...3600).contains(challenge.expires_in),
              challenge.interval.map({ $0.isFinite && $0 >= 1 && $0 <= 60 }) ?? true else {
            throw T3ConnectError.invalidResponse
        }
        _ = try verificationURL(challenge)
        return challenge
    }

    func verificationURL(_ challenge: T3ConnectDeviceChallenge) throws -> URL {
        guard let url = URL(string: challenge.verification_uri_complete ?? challenge.verification_uri),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.user == nil, parts.password == nil,
              parts.host == configuration.issuer.host || parts.host == "accounts.t3.codes" else {
            throw T3ConnectError.invalidResponse
        }
        return url
    }

    func pollDevice(_ challenge: T3ConnectDeviceChallenge, metadata: T3ConnectOAuthMetadata) async throws -> T3ConnectDevicePoll {
        let (data, response) = try await send(request(try issuerEndpoint(metadata.token_endpoint), form: [
            "client_id": configuration.oauthClientID, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": challenge.device_code
        ]))
        if response.statusCode == 200 { return .authorized(try tokens(data)) }
        let code = (try? JSONDecoder().decode(OAuthError.self, from: data))?.error
        if code == "authorization_pending" { return .pending }
        if code == "slow_down" || response.statusCode == 429 { return .slowDown }
        if code == "access_denied" { throw T3ConnectError.declined }
        if code == "expired_token" || code == "invalid_grant" { throw T3ConnectError.expired }
        if response.statusCode >= 500 { throw T3ConnectError.unavailable }
        throw T3ConnectError.invalidResponse
    }

    func refresh(_ previous: T3ConnectCloudTokens, metadata: T3ConnectOAuthMetadata) async throws -> T3ConnectCloudTokens {
        guard !previous.refreshToken.isEmpty else { throw T3ConnectError.signInRequired }
        let data = try await success(request(try issuerEndpoint(metadata.token_endpoint), form: [
            "client_id": configuration.oauthClientID, "grant_type": "refresh_token", "refresh_token": previous.refreshToken
        ]), oauth: true)
        return try tokens(data, previousRefresh: previous.refreshToken)
    }

    func identity(tokens: T3ConnectCloudTokens, metadata: T3ConnectOAuthMetadata) async throws -> T3ConnectIdentity {
        let data = try await success(request(try issuerEndpoint(metadata.userinfo_endpoint), bearer: tokens.accessToken))
        guard let identity = try? JSONDecoder().decode(T3ConnectIdentity.self, from: data), !identity.sub.isEmpty else {
            throw T3ConnectError.invalidResponse
        }
        return identity
    }

    func environments(accessToken: String) async throws -> [T3ConnectEnvironment] {
        struct List: Decodable { let environments: [T3ConnectEnvironment] }
        let data = try await success(request(configuration.relay.appendingPathComponent("v1/environments"), bearer: accessToken))
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw T3ConnectError.invalidResponse }
        var seen: Set<String> = []
        return try list.environments.filter { seen.insert($0.id).inserted }.map { environment in
            guard !environment.id.isEmpty, !environment.label.isEmpty else { throw T3ConnectError.invalidResponse }
            _ = try cloudOrigin(environment.endpoint.httpBaseUrl)
            return environment
        }
    }

    func mint(environment: T3ConnectEnvironment, accessToken: String, proofKey: T3DPoPKey) async throws -> String {
        struct RelayToken: Decodable { let access_token: String; let token_type: String; let scope: String; let expires_in: Double }
        let exchangeURL = configuration.relay.appendingPathComponent("v1/client/dpop-token")
        var exchange = request(exchangeURL, form: [
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange", "subject_token": accessToken,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "resource": configuration.relay.absoluteString, "scope": "environment:connect", "client_id": "t3-web"
        ])
        exchange.setValue(try proofKey.proof(method: "POST", url: exchangeURL), forHTTPHeaderField: "DPoP")
        let data = try await success(exchange)
        guard let token = try? JSONDecoder().decode(RelayToken.self, from: data), token.token_type == "DPoP",
              !token.access_token.isEmpty, token.expires_in.isFinite, token.expires_in > 0,
              Set(token.scope.split(whereSeparator: \.isWhitespace)) == ["environment:connect"] else {
            throw T3ConnectError.invalidResponse
        }
        var parts = URLComponents(url: configuration.relay, resolvingAgainstBaseURL: false)!
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        guard let id = environment.id.addingPercentEncoding(withAllowedCharacters: allowed), id != ".", id != ".." else {
            throw T3ConnectError.invalidResponse
        }
        parts.percentEncodedPath = "/v1/environments/\(id)/connect"
        var connect = request(parts.url!, json: ["clientProofKeyThumbprint": proofKey.thumbprint])
        try proofKey.authorize(&connect, token: token.access_token)
        struct Bootstrap: Decodable {
            let environmentId: String
            let endpoint: T3ConnectEnvironment.Endpoint
            let credential: String
            let expiresAt: String
        }
        let bootstrapData = try await success(connect)
        guard let bootstrap = try? JSONDecoder().decode(Bootstrap.self, from: bootstrapData),
              bootstrap.environmentId == environment.id,
              try cloudOrigin(bootstrap.endpoint.httpBaseUrl) == cloudOrigin(environment.endpoint.httpBaseUrl),
              let expires = T3ShellSnapshot.date(bootstrap.expiresAt), expires > Date(), !bootstrap.credential.isEmpty else {
            throw T3ConnectError.environmentMismatch
        }
        return bootstrap.credential
    }

    func revoke(_ tokens: T3ConnectCloudTokens, metadata: T3ConnectOAuthMetadata) async {
        guard let endpoint = metadata.revocation_endpoint, let url = try? issuerEndpoint(endpoint) else { return }
        _ = try? await success(request(url, form: ["client_id": configuration.oauthClientID,
            "token": tokens.refreshToken.isEmpty ? tokens.accessToken : tokens.refreshToken,
            "token_type_hint": tokens.refreshToken.isEmpty ? "access_token" : "refresh_token"]))
    }

    private struct OAuthError: Decodable { let error: String }
    private struct Token: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let token_type: String
    }

    private func tokens(_ data: Data, previousRefresh: String = "") throws -> T3ConnectCloudTokens {
        guard let token = try? JSONDecoder().decode(Token.self, from: data), !token.access_token.isEmpty,
              token.token_type.lowercased() == "bearer", token.expires_in.isFinite, token.expires_in > 0 else {
            throw T3ConnectError.invalidResponse
        }
        return T3ConnectCloudTokens(accessToken: token.access_token, refreshToken: token.refresh_token ?? previousRefresh,
                                    expiresAt: Date().addingTimeInterval(token.expires_in))
    }

    private func cloudOrigin(_ value: String) throws -> URL {
        guard let url = try? T3CodeClient(transport: transport).validateEndpoint(value), url.scheme == "https" else { throw T3ConnectError.invalidResponse }
        return url
    }

    private func issuerEndpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == configuration.issuer.host, parts.port == configuration.issuer.port,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw T3ConnectError.invalidResponse
        }
        return url
    }

    private func request(_ url: URL, form: [String: String]? = nil, json: [String: String]? = nil,
                         bearer: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Vorssaint-T3-Connect/1", forHTTPHeaderField: "User-Agent")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = form.sorted { $0.key < $1.key }.map {
                $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
            }.joined(separator: "&").data(using: .utf8)
        } else if let json {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse, data.count <= 1 << 20 else { throw T3ConnectError.invalidResponse }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as T3ConnectError { throw error }
        catch { throw T3ConnectError.unavailable }
    }

    private func success(_ request: URLRequest, oauth: Bool = false) async throws -> Data {
        let (data, response) = try await send(request)
        if response.statusCode == 401 || (oauth && response.statusCode == 400) { throw T3ConnectError.signInRequired }
        if response.statusCode == 429 || response.statusCode >= 500 { throw T3ConnectError.unavailable }
        guard (200...299).contains(response.statusCode) else { throw T3ConnectError.invalidResponse }
        return data
    }
}

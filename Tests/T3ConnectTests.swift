// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CryptoKit
import Foundation

enum T3ConnectTests {
    private static let configuration = T3ConnectConfiguration(issuer: URL(string: "https://auth.example.test")!,
        relay: URL(string: "https://relay.example.test")!, oauthClientID: "public-test-client")

    static func run(_ suite: TestSuite) {
        proofs(suite)
        let done = DispatchSemaphore(value: 0)
        Task.detached { await client(suite); done.signal() }
        suite.expect(done.wait(timeout: .now() + 10) == .success, "Connect client tests finish without real sign-in")
        let finished = Completion()
        Task { @MainActor in await lifecycle(suite); finished.finish() }
        let deadline = Date().addingTimeInterval(10)
        while !finished.done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        suite.expect(finished.done, "Connect lifecycle tests finish without browser interaction")
        for language in AppLanguage.allCases {
            let text = T3ConnectStrings(language)
            suite.expect([text.signIn, text.signOut, text.refresh, text.cancel, text.browser, text.waiting,
                          text.empty, text.help, text.manual, text.error(.expired), text.error(.signInRequired)].allSatisfy { !$0.isEmpty },
                         "Connect controls and errors are localized in \(language)")
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var done: Bool { lock.withLock { value } }
        func finish() { lock.withLock { value = true } }
    }

    private static func decodePart(_ value: Substring) -> Data {
        var string = String(value).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while string.count % 4 != 0 { string += "=" }
        return Data(base64Encoded: string)!
    }

    private static func proofs(_ suite: TestSuite) {
        let key = T3DPoPKey()
        let restored = try! T3DPoPKey(stored: key.stored)
        suite.expect(restored.thumbprint == key.thumbprint && key.publicJWK["d"] == nil,
                     "Connect proof key survives storage and never exports private JWK material")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let proof = try! key.proof(method: "get", url: URL(string: "https://EXAMPLE.test:443/path?private=value#fragment")!,
                                   accessToken: "access-token", now: date, identifier: "proof-1")
        let parts = proof.split(separator: ".")
        let header = try! JSONSerialization.jsonObject(with: decodePart(parts[0])) as! [String: Any]
        let payload = try! JSONSerialization.jsonObject(with: decodePart(parts[1])) as! [String: Any]
        suite.expect(header["typ"] as? String == "dpop+jwt" && header["alg"] as? String == "ES256",
                     "Connect uses the server's required DPoP JWT type and ES256 algorithm")
        suite.expect(payload["htu"] as? String == "https://example.test/path" && payload["htm"] as? String == "GET",
                     "DPoP canonicalizes scheme/host/default port and excludes query and fragment")
        suite.expect(payload["ath"] as? String == T3DPoPKey.base64URL(SHA256.hash(data: Data("access-token".utf8)))
                     && payload["jti"] as? String == "proof-1" && payload["iat"] as? Int == Int(date.timeIntervalSince1970),
                     "proof binds the access token, timestamp and unique request identity")
        let jwk = header["jwk"] as! [String: String]
        let publicBytes = Data([4]) + decodePart(Substring(jwk["x"]!)) + decodePart(Substring(jwk["y"]!))
        let publicKey = try! P256.Signing.PublicKey(x963Representation: publicBytes)
        let signature = try! P256.Signing.ECDSASignature(rawRepresentation: decodePart(parts[2]))
        suite.expect(publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)),
                     "exported public JWK verifies the actual compact DPoP signature")
        suite.expect(!publicKey.isValidSignature(signature, for: Data("tampered".utf8)), "changed proof payload fails verification")
        let bootstrap = try! key.proof(method: "POST", url: URL(string: "https://example.test/oauth/token")!)
        let bootstrapPayload = try! JSONSerialization.jsonObject(with: decodePart(bootstrap.split(separator: ".")[1])) as! [String: Any]
        suite.expect(bootstrapPayload["ath"] == nil && bootstrap != proof, "bootstrap proof has a fresh identity without a fabricated access-token hash")
        suite.expect((try? T3DPoPKey(stored: "broken")) == nil, "invalid private key storage is rejected")
    }

    private static func client(_ suite: TestSuite) async {
        let transport = FixtureTransport()
        let client = T3ConnectClient(configuration: configuration, transport: transport)
        do {
            let metadata = try await client.metadata()
            let challenge = try await client.beginDeviceAuthorization(metadata: metadata)
            suite.expect(challenge.user_code == "ABCD-EFGH", "device sign-in exposes only the approval code to the UI")
            transport.pollError = "authorization_pending"
            if case .pending = try await client.pollDevice(challenge, metadata: metadata) { suite.expect(true, "pending device authorization keeps waiting") }
            else { suite.expect(false, "pending device authorization must not sign in") }
            transport.pollError = "slow_down"
            if case .slowDown = try await client.pollDevice(challenge, metadata: metadata) { suite.expect(true, "device flow honors server backoff") }
            else { suite.expect(false, "server backoff must be honored") }
            transport.pollError = nil
            guard case .authorized(let tokens) = try await client.pollDevice(challenge, metadata: metadata) else {
                suite.expect(false, "approved device flow returns tokens"); return
            }
            let identity = try await client.identity(tokens: tokens, metadata: metadata)
            suite.expect(identity.sub == "user-1" && identity.label == "Test account", "account label comes from the signed-in user's userinfo")
            let refreshed = try await client.refresh(tokens, metadata: metadata)
            suite.expect(refreshed.refreshToken == "rotated-refresh", "OAuth refresh keeps a rotated refresh token")
            let environments = try await client.environments(accessToken: tokens.accessToken)
            suite.expect(environments.count == 1 && environments[0].label == "Development", "Connect discovers linked machines")
            let key = T3DPoPKey()
            let bootstrap = try await client.mint(environment: environments[0], accessToken: tokens.accessToken, proofKey: key)
            suite.expect(bootstrap == "proof-bound-bootstrap", "relay supplies a one-time environment bootstrap")
            let requests = transport.requests
            let relayExchange = requests.first { $0.url?.path == "/v1/client/dpop-token" }!
            let form = String(data: relayExchange.httpBody!, encoding: .utf8)!
            suite.expect(form.contains("scope=environment%3Aconnect") && !form.contains("mobile") && relayExchange.value(forHTTPHeaderField: "DPoP") != nil,
                         "relay grant requests only environment connection access and binds it to this client's key")
            let mint = requests.first { $0.url?.path == "/v1/environments/env-1/connect" }!
            let body = try JSONSerialization.jsonObject(with: mint.httpBody!) as! [String: String]
            suite.expect(mint.value(forHTTPHeaderField: "Authorization") == "DPoP relay-token"
                         && body["clientProofKeyThumbprint"] == key.thumbprint,
                         "environment bootstrap is requested with proof-bound relay access")
            suite.expect(requests.allSatisfy { $0.url?.host != "machine.example.test" }, "cloud credentials never go to an environment")
            transport.bootstrapEnvironmentID = "wrong-environment"
            do { _ = try await client.mint(environment: environments[0], accessToken: tokens.accessToken, proofKey: key)
                suite.expect(false, "minted identity mismatch must fail")
            } catch { suite.expect(error as? T3ConnectError == .environmentMismatch, "minted environment identity is checked before use") }
            transport.bootstrapEnvironmentID = "env-1"
            transport.relayScope = "environment:connect mobile:registration"
            do { _ = try await client.mint(environment: environments[0], accessToken: tokens.accessToken, proofKey: key)
                suite.expect(false, "unexpected relay permissions must fail")
            } catch { suite.expect(error as? T3ConnectError == .invalidResponse, "overprivileged relay tokens are rejected") }
            transport.deviceEndpoint = "https://untrusted.example/oauth/device"
            let changed = try await client.metadata()
            let before = transport.requests.count
            do { _ = try await client.beginDeviceAuthorization(metadata: changed); suite.expect(false, "cross-origin auth endpoint must fail") }
            catch { suite.expect(transport.requests.count == before, "metadata cannot redirect OAuth secrets to another origin") }
        } catch { suite.expect(false, "Connect protocol fixture failed: \(error)") }
    }

    @MainActor private static func lifecycle(_ suite: TestSuite) async {
        let name = "vorssaint.connect.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FixtureTransport()
        let credentials = Credentials()
        let activity = T3CodeActivityService(client: T3CodeClient(transport: transport), credentials: credentials, defaults: defaults)
        var enabled = true
        let service = T3ConnectService(client: T3ConnectClient(configuration: configuration, transport: transport),
            credentials: credentials, activity: activity, defaults: defaults, featureEnabled: { enabled },
            waitForPoll: { _ in await Task.yield() })
        defer { service.pause(); activity.stop(clearActivity: true) }
        service.signIn()
        await wait { !service.busy }
        suite.expect(service.state == .signedIn && service.environments.count == 1,
                     "native coordinator signs in and discovers machines with its own authorization")
        suite.expect(credentials.values[T3ConnectService.accountKey] != nil && credentials.values.keys.contains { $0.hasPrefix("t3-connect.proof.") },
                     "cloud refresh token and proof key are persisted only through the credential store")
        service.connect(service.environments[0])
        await wait { !service.busy }
        let saved = activity.cloudConnections(accountID: "user-1")
        suite.expect(saved.count == 1 && saved[0].proofKeyAccount != nil && service.error == nil,
                     "machine selection persists a proof-bound read session owned by the signed-in account")
        let requests = transport.requests.filter { $0.url?.host == "machine.example.test" }
        suite.expect(requests.contains { $0.value(forHTTPHeaderField: "Authorization") == "DPoP environment-token" }
            && !requests.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer cloud-token" },
                     "coordinator hands off environment access without exposing its cloud login")
        service.pause()
        let restored = T3ConnectService(client: T3ConnectClient(configuration: configuration, transport: transport),
            credentials: credentials, activity: activity, defaults: defaults, featureEnabled: { enabled })
        restored.refresh()
        await wait { !restored.busy }
        suite.expect(restored.state == .signedIn && restored.environments.count == 1,
                     "a new coordinator restores its own account and proof key without another login")
        restored.pause()
        if let saved = saved.first {
            service.reconnect(connectionID: saved.id)
            await wait { !service.busy }
            suite.expect(activity.cloudConnections().count == 1 && service.error == nil,
                         "Connect re-pair renews the session without duplicating its environment")
        }
        let manual = T3ConfiguredConnection(id: "manual", endpoint: "https://manual.example.test", environmentID: "manual-env",
            label: "Manual", machine: nil, credentialID: nil, expiresAt: Date().addingTimeInterval(3600))
        T3ConfiguredConnectionStore(defaults: defaults).save(activity.cloudConnections() + [manual])
        let staleCredentials = credentials.values
        service.signOut()
        await Task.yield()
        await wait { !service.busy }
        suite.expect(service.state == .signedOut && credentials.values.isEmpty, "sign-out removes this client's cloud credentials and proof key")
        suite.expect(T3ConfiguredConnectionStore(defaults: defaults).load() == [manual], "Connect sign-out preserves manually paired environments")
        // Model Keychain deletion failing while locked, then becoming readable
        // in a later process. Explicit sign-out must still win.
        for (key, value) in staleCredentials { _ = credentials.write(value, account: key) }
        let afterSignOut = T3ConnectService(client: T3ConnectClient(configuration: configuration, transport: transport),
            credentials: credentials, activity: activity, defaults: defaults, featureEnabled: { enabled })
        let requestsBeforeRestore = transport.requests.count
        afterSignOut.refresh()
        await wait { !afterSignOut.busy }
        suite.expect(afterSignOut.state == .signedOut && transport.requests.count == requestsBeforeRestore,
                     "a stale Keychain item cannot resurrect an explicitly signed-out account")
        suite.expect(SettingsBackupSupport.machineStateKeys.contains(DefaultsKey.notchAgentsT3ConnectSignedOut),
                     "the device's Connect sign-out state is excluded from settings exports")
        afterSignOut.pause()
        for key in staleCredentials.keys { credentials.remove(account: key) }
        transport.holdDevicePoll = true
        service.signIn()
        await wait { transport.isHoldingPoll }
        suite.expect(service.verificationURL?.host == configuration.issuer.host && service.userCode == "ABCD-EFGH",
                     "sign-in exposes the link and approval code for the user to open themselves")
        service.cancelAuthorization()
        transport.releasePoll()
        await Task.yield()
        await Task.yield()
        suite.expect(service.state == .signedOut && credentials.values.isEmpty,
                     "late OAuth success after cancellation cannot resurrect account credentials")
        enabled = false
        let before = transport.requests.count
        service.signIn(); service.refresh(); service.syncWithPreferences()
        await Task.yield()
        suite.expect(transport.requests.count == before && !service.busy, "disabled AI Agents does not start Connect requests")
    }

    @MainActor private static func wait(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private final class Credentials: T3CredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: String] = [:]
        var values: [String: String] { lock.withLock { stored } }
        func read(account: String) -> T3CredentialLookup { lock.withLock { stored[account].map(T3CredentialLookup.found) ?? .missing } }
        func write(_ token: String, account: String) -> Bool { lock.withLock { stored[account] = token }; return true }
        func remove(account: String) { _ = lock.withLock { stored.removeValue(forKey: account) } }
    }

    private final class FixtureTransport: T3CodeHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        var requests: [URLRequest] { lock.withLock { recorded } }
        var pollError: String?
        var deviceEndpoint = "https://auth.example.test/oauth/device_authorization"
        var bootstrapEnvironmentID = "env-1"
        var relayScope = "environment:connect"
        var holdDevicePoll = false
        var isHoldingPoll: Bool { lock.withLock { continuation != nil } }

        func releasePoll() {
            let held = lock.withLock { let value = continuation; continuation = nil; return value }
            held?.resume(returning: response(URL(string: "https://auth.example.test/oauth/token")!, token))
        }

        private var token: [String: Any] { ["access_token": "cloud-token", "refresh_token": "rotated-refresh", "expires_in": 3600, "token_type": "Bearer"] }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.withLock { recorded.append(request) }
            let url = request.url!
            let endpoint: [String: String] = ["httpBaseUrl": "https://machine.example.test"]
            switch url.path {
            case "/.well-known/openid-configuration":
                return response(url, ["issuer": configuration.issuer.absoluteString, "token_endpoint": "https://auth.example.test/oauth/token",
                    "userinfo_endpoint": "https://auth.example.test/oauth/userinfo", "device_authorization_endpoint": deviceEndpoint,
                    "revocation_endpoint": "https://auth.example.test/oauth/revoke"])
            case "/oauth/device_authorization":
                return response(url, ["device_code": "private-device-code", "user_code": "ABCD-EFGH",
                    "verification_uri": "https://auth.example.test/device", "expires_in": 300, "interval": 1])
            case "/oauth/token":
                if url.host == "machine.example.test" {
                    return response(url, ["access_token": "environment-token", "token_type": "DPoP", "scope": "orchestration:read",
                        "issued_token_type": "urn:ietf:params:oauth:token-type:access_token", "expires_in": 3600])
                }
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("device_code") {
                    if holdDevicePoll { return try await withCheckedThrowingContinuation { continuation in lock.withLock { self.continuation = continuation } } }
                    if let pollError { return response(url, ["error": pollError], status: 400) }
                }
                return response(url, token)
            case "/oauth/userinfo": return response(url, ["sub": "user-1", "name": "Test account"])
            case "/v1/environments": return response(url, ["environments": [["environmentId": "env-1", "label": "Development", "endpoint": endpoint]]])
            case "/v1/client/dpop-token": return response(url, ["access_token": "relay-token", "token_type": "DPoP", "scope": relayScope, "expires_in": 300])
            case "/v1/environments/env-1/connect": return response(url, ["environmentId": bootstrapEnvironmentID,
                "endpoint": endpoint, "credential": "proof-bound-bootstrap", "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))])
            case "/oauth/revoke": return response(url, [:])
            case "/.well-known/t3/environment": return response(url, ["environmentId": "env-1", "label": "Development",
                "platform": ["machine": "dev-01"], "orchestrationProtocolVersion": 2])
            case "/api/orchestration/shell": return response(url, ["threads": [], "archivedThreads": [], "projects": []])
            default: return response(url, [:], status: 404)
            }
        }

        private func response(_ url: URL, _ object: [String: Any], status: Int = 200) -> (Data, URLResponse) {
            (try! JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

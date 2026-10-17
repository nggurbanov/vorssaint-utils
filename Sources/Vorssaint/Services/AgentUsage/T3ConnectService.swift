// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

enum T3ConnectState: Equatable { case signedOut, authorizing, signedIn, needsSignIn, unavailable }

/// A separate account for this client. Never imports T3 Desktop/CLI credentials.
final class T3ConnectService: ObservableObject {
    static let shared = T3ConnectService()
    static let accountKey = "t3-connect.account.v1"

    struct Account: Codable {
        let version: Int
        let issuer: String
        let relay: String
        let clientID: String
        let subject: String
        let label: String
        var tokens: T3ConnectCloudTokens
        let proofKeyAccount: String
    }

    @Published private(set) var state: T3ConnectState = .signedOut
    @Published private(set) var accountLabel: String?
    @Published private(set) var environments: [T3ConnectEnvironment] = []
    @Published private(set) var userCode: String?
    @Published private(set) var verificationURL: URL?
    @Published private(set) var busy = false
    @Published private(set) var connectingEnvironmentID: String?
    @Published private(set) var error: T3ConnectError?

    private let client: T3ConnectClient
    private let credentials: T3CredentialStore
    private let activity: T3CodeActivityService
    private let defaults: UserDefaults
    private let featureEnabled: () -> Bool
    private let waitForPoll: (Double) async throws -> Void
    private var account: Account?
    private var operation: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var refreshTask: Task<T3ConnectCloudTokens, Error>?
    private var generation = UUID()

    init(client: T3ConnectClient = T3ConnectClient(), credentials: T3CredentialStore = T3KeychainCredentialStore(),
         activity: T3CodeActivityService = .shared, defaults: UserDefaults = .standard,
         featureEnabled: (() -> Bool)? = nil,
         waitForPoll: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.client = client
        self.credentials = credentials
        self.activity = activity
        self.defaults = defaults
        self.featureEnabled = featureEnabled ?? { NotchAgentSupport.isEnabled(in: defaults) }
        self.waitForPoll = waitForPoll
    }

    func syncWithPreferences() {
        guard featureEnabled() else { pause(); return }
        guard maintenance == nil else { return }
        let generation = self.generation
        maintenance = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == generation {
                if self.operation == nil {
                    do {
                        if self.account == nil { try await self.restore(generation: generation) }
                        if self.account != nil {
                            try await self.reload(generation: generation)
                            try await self.repairSavedConnections(generation: generation)
                        }
                    } catch is CancellationError { return }
                    catch { self.report(error, generation: generation) }
                }
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    func signIn() {
        guard !busy, featureEnabled() else { return }
        cancelOperations()
        let generation = self.generation
        busy = true
        error = nil
        state = .authorizing
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(generation: generation) }
            do {
                if self.account == nil {
                    do { try await self.restore(generation: generation) }
                    catch T3ConnectError.signInRequired { }
                    try self.check(generation)
                    self.state = .authorizing
                }
                let metadata = try await self.client.metadata()
                let challenge = try await self.client.beginDeviceAuthorization(metadata: metadata)
                try self.check(generation)
                self.userCode = challenge.user_code
                let url = try self.client.verificationURL(challenge)
                self.verificationURL = url
                let deadline = Date().addingTimeInterval(challenge.expires_in)
                var interval = challenge.interval ?? 5
                var authorized: T3ConnectCloudTokens?
                while Date() < deadline, authorized == nil {
                    try await self.waitForPoll(interval)
                    try self.check(generation)
                    do {
                        switch try await self.client.pollDevice(challenge, metadata: metadata) {
                        case .pending: break
                        case .slowDown: interval = min(60, interval + 5)
                        case .authorized(let tokens): authorized = tokens
                        }
                    } catch T3ConnectError.unavailable { interval = min(60, interval + 5) }
                }
                guard let tokens = authorized else { throw T3ConnectError.expired }
                try self.check(generation)
                let identity = try await self.client.identity(tokens: tokens, metadata: metadata)
                try self.check(generation)
                let old = self.account
                let previousKey = old?.subject == identity.sub ? old?.proofKeyAccount : nil
                let key = try await self.loadProofKey(account: previousKey) ?? T3DPoPKey()
                try self.check(generation)
                let keyAccount = previousKey ?? "t3-connect.proof." + UUID().uuidString
                guard self.write(key.stored, to: keyAccount) else { throw T3ConnectError.keychainUnavailable }
                try self.check(generation)
                let account = Account(version: 1, issuer: self.client.configuration.issuer.absoluteString,
                    relay: self.client.configuration.relay.absoluteString, clientID: self.client.configuration.oauthClientID,
                    subject: identity.sub, label: identity.label, tokens: tokens, proofKeyAccount: keyAccount)
                guard try self.save(account) else {
                    if previousKey == nil { self.remove(keyAccount) }
                    throw T3ConnectError.keychainUnavailable
                }
                try self.check(generation)
                if let old, old.subject != identity.sub {
                    self.removeConnections(accountID: old.subject)
                    self.remove(old.proofKeyAccount)
                }
                // Also handle an old/corrupt account record that could not be
                // restored: a new login must not retain another account's reads.
                for connection in self.activity.cloudConnections() where connection.cloudAccountID != identity.sub {
                    self.activity.disconnect(connectionID: connection.id)
                    if let key = connection.proofKeyAccount, key != keyAccount { self.remove(key) }
                }
                self.account = account
                self.defaults.set(false, forKey: DefaultsKey.notchAgentsT3ConnectSignedOut)
                self.accountLabel = account.label
                self.state = .signedIn
                self.userCode = nil
                self.verificationURL = nil
                try await self.reload(generation: generation)
                try await self.repairSavedConnections(generation: generation)
            } catch is CancellationError { }
            catch { self.report(error, generation: generation) }
        }
    }

    func cancelAuthorization() {
        guard state == .authorizing else { return }
        cancelOperations()
        userCode = nil
        verificationURL = nil
        state = account == nil ? .signedOut : .needsSignIn
        syncWithPreferences()
    }

    func refresh() {
        guard !busy, featureEnabled() else { return }
        let generation = self.generation
        busy = true
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(generation: generation) }
            do {
                if self.account == nil { try await self.restore(generation: generation) }
                guard self.account != nil else { return }
                try await self.reload(generation: generation)
                try await self.repairSavedConnections(generation: generation)
            } catch is CancellationError { }
            catch { self.report(error, generation: generation) }
        }
    }

    func connect(_ environment: T3ConnectEnvironment) {
        guard !busy, account != nil, featureEnabled() else { return }
        let generation = self.generation
        busy = true
        error = nil
        connectingEnvironmentID = environment.id
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(generation: generation) }
            do { try await self.connect(environment, generation: generation) }
            catch is CancellationError { }
            catch { self.report(error, generation: generation) }
        }
    }

    func signOut() {
        let previous = account
        let connections = activity.cloudConnections()
        let proofAccounts = Set(connections.compactMap(\.proofKeyAccount) + [previous?.proofKeyAccount].compactMap { $0 })
        cancelOperations()
        let generation = self.generation
        // A locked Keychain can refuse deletion. Persist the explicit sign-out
        // independently so a surviving item cannot silently restore the login.
        defaults.set(true, forKey: DefaultsKey.notchAgentsT3ConnectSignedOut)
        for connection in connections { activity.disconnect(connectionID: connection.id) }
        remove(Self.accountKey)
        for key in proofAccounts { remove(key) }
        account = nil
        accountLabel = nil
        environments = []
        userCode = nil
        verificationURL = nil
        error = nil
        state = .signedOut
        busy = true
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(generation: generation) }
            if let previous {
                if let metadata = try? await self.client.metadata() { await self.client.revoke(previous.tokens, metadata: metadata) }
            }
        }
    }

    func reconnect(connectionID: String) {
        guard !busy, featureEnabled(), let connection = activity.cloudConnections().first(where: { $0.id == connectionID }) else { return }
        let generation = self.generation
        busy = true
        error = nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(generation: generation) }
            do {
                if self.account == nil { try await self.restore(generation: generation) }
                guard self.account?.subject == connection.cloudAccountID else { throw T3ConnectError.signInRequired }
                try await self.reload(generation: generation)
                guard let environment = self.environments.first(where: { $0.id == connection.environmentID }) else {
                    throw T3ConnectError.unavailable
                }
                try await self.connect(environment, generation: generation)
            } catch is CancellationError { }
            catch { self.report(error, generation: generation) }
        }
    }

    func pause() {
        let wasAuthorizing = state == .authorizing
        cancelOperations()
        environments = []
        userCode = nil
        verificationURL = nil
        if wasAuthorizing { state = account == nil ? .signedOut : .needsSignIn }
    }

    private func cancelOperations() {
        generation = UUID()
        operation?.cancel(); operation = nil
        maintenance?.cancel(); maintenance = nil
        refreshTask?.cancel(); refreshTask = nil
        busy = false
        connectingEnvironmentID = nil
    }

    private func finishOperation(generation: UUID) {
        guard self.generation == generation else { return }
        operation = nil
        busy = false
        connectingEnvironmentID = nil
        userCode = nil
        verificationURL = nil
        syncWithPreferences()
    }

    private func check(_ generation: UUID) throws {
        guard !Task.isCancelled, self.generation == generation else { throw CancellationError() }
    }

    @MainActor private func restore(generation: UUID) async throws {
        if defaults.bool(forKey: DefaultsKey.notchAgentsT3ConnectSignedOut) { state = .signedOut; return }
        let credentials = self.credentials
        let stored = await Task.detached(priority: .utility) { credentials.read(account: Self.accountKey) }.value
        try check(generation)
        switch stored {
        case .missing: state = .signedOut
        case .retryable: throw T3ConnectError.keychainUnavailable
        case .found(let value):
            guard let data = value.data(using: .utf8), let account = try? JSONDecoder().decode(Account.self, from: data),
                  account.version == 1, account.issuer == client.configuration.issuer.absoluteString,
                  account.relay == client.configuration.relay.absoluteString, account.clientID == client.configuration.oauthClientID,
                  !account.subject.isEmpty, !account.proofKeyAccount.isEmpty else { throw T3ConnectError.signInRequired }
            guard try await loadProofKey(account: account.proofKeyAccount) != nil else { throw T3ConnectError.signInRequired }
            try check(generation)
            self.account = account
            accountLabel = account.label
            state = .signedIn
        }
    }

    @MainActor private func accessToken(generation: UUID, forceRefresh: Bool = false) async throws -> String {
        try check(generation)
        guard let account else { throw T3ConnectError.signInRequired }
        if !forceRefresh, account.tokens.expiresAt.timeIntervalSinceNow > 60 { return account.tokens.accessToken }
        if let refreshTask {
            let tokens = try await refreshTask.value
            try check(generation)
            return tokens.accessToken
        }
        let client = self.client
        let task = Task { () throws -> T3ConnectCloudTokens in
            let metadata = try await client.metadata()
            return try await client.refresh(account.tokens, metadata: metadata)
        }
        refreshTask = task
        defer { if self.generation == generation { refreshTask = nil } }
        let tokens = try await task.value
        try check(generation)
        var updated = account
        updated.tokens = tokens
        self.account = updated // Retain rotated tokens in RAM if Keychain is temporarily locked.
        guard try save(updated) else { throw T3ConnectError.keychainUnavailable }
        try check(generation)
        return tokens.accessToken
    }

    @MainActor private func reload(generation: UUID) async throws {
        var token = try await accessToken(generation: generation)
        let next: [T3ConnectEnvironment]
        do { next = try await client.environments(accessToken: token) }
        catch T3ConnectError.signInRequired {
            token = try await accessToken(generation: generation, forceRefresh: true)
            next = try await client.environments(accessToken: token)
        }
        try check(generation)
        environments = next.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        state = .signedIn
        error = nil
    }

    @MainActor private func connect(_ environment: T3ConnectEnvironment, generation: UUID) async throws {
        guard let account else { throw T3ConnectError.signInRequired }
        var token = try await accessToken(generation: generation)
        guard let proofKey = try await loadProofKey(account: account.proofKeyAccount) else { throw T3ConnectError.signInRequired }
        try check(generation)
        let bootstrap: String
        do { bootstrap = try await client.mint(environment: environment, accessToken: token, proofKey: proofKey) }
        catch T3ConnectError.signInRequired {
            token = try await accessToken(generation: generation, forceRefresh: true)
            bootstrap = try await client.mint(environment: environment, accessToken: token, proofKey: proofKey)
        }
        try check(generation)
        try await activity.connect(endpoint: environment.endpoint.httpBaseUrl, pairingCode: bootstrap,
            proofKey: proofKey, proofKeyAccount: account.proofKeyAccount,
            cloudAccountID: account.subject, expectedEnvironmentID: environment.id)
        try check(generation)
        error = nil
    }

    @MainActor private func repairSavedConnections(generation: UUID) async throws {
        guard let account else { return }
        for connection in activity.cloudConnections(accountID: account.subject) {
            try check(generation)
            let needsPairing = activity.connectionStatuses.first { $0.id == connection.id }?.state == .needsPairing
            guard connection.expiresAt.timeIntervalSinceNow < 600 || needsPairing,
                  let environment = environments.first(where: { $0.id == connection.environmentID }) else { continue }
            do { try await connect(environment, generation: generation) }
            catch is CancellationError { throw CancellationError() }
            catch T3ConnectError.signInRequired { throw T3ConnectError.signInRequired }
            catch { report(error, generation: generation) }
        }
    }

    private func removeConnections(accountID: String) {
        for connection in activity.cloudConnections(accountID: accountID) { activity.disconnect(connectionID: connection.id) }
    }

    private func report(_ failure: Error, generation: UUID) {
        guard self.generation == generation else { return }
        error = failure as? T3ConnectError ?? .unavailable
        if error == .signInRequired { state = .needsSignIn }
        else if state == .authorizing { state = account == nil ? .signedOut : .needsSignIn }
        else if account == nil { state = .unavailable }
    }

    @MainActor private func loadProofKey(account: String?) async throws -> T3DPoPKey? {
        guard let account else { return nil }
        let credentials = self.credentials
        switch await Task.detached(priority: .utility, operation: { credentials.read(account: account) }).value {
        case .missing: return nil
        case .retryable: throw T3ConnectError.keychainUnavailable
        case .found(let value):
            guard let key = try? T3DPoPKey(stored: value) else { throw T3ConnectError.signInRequired }
            return key
        }
    }

    private func save(_ account: Account) throws -> Bool {
        let data = try JSONEncoder().encode(account)
        return write(String(decoding: data, as: UTF8.self), to: Self.accountKey)
    }

    // Writes are short, silent Keychain transactions. Commit without an await
    // between the generation check and the write, so sign-out/cancellation cannot
    // race a stale token write. Network and Keychain reads stay asynchronous.
    private func write(_ value: String, to account: String) -> Bool {
        credentials.write(value, account: account)
    }

    private func remove(_ account: String) {
        credentials.remove(account: account)
    }
}

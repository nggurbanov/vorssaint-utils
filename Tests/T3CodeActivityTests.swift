// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Lifecycle cases informed by Bruno Hjorth (liltaket), PR #2747.

import Foundation

/// Contract checks target the v0.1.0 wire schema, not a copied provider log.
enum T3CodeActivityTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-10-17T10:00:00Z")!
    private static let identity = T3EnvironmentIdentity(id: "env-1", label: "Development", machine: "dev-01")

    static func run(_ suite: TestSuite) {
        T3AgentNoticeTests.run(suite)
        mapping(suite)
        transitions(suite)
        presentation(suite)
        configuration(suite)
        MainActor.assumeIsolated { expiry(suite) }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await client(suite)
            done.signal()
        }
        suite.expect(done.wait(timeout: .now() + 10) == .success, "T3 transport checks finish within a bounded timeout")
        for language in AppLanguage.allCases {
            let strings = T3CodeStrings(language)
            for state: T3ThreadState in [.working, .waiting, .waitingForInput, .waitingForApproval, .waitingForPlan,
                                         .limited, .idle, .completed, .failed, .stopped] {
                suite.expect(!strings.stateText(state).isEmpty, "T3 state has a label in \(language)")
            }
        }
    }

    private static func wire(status: String = "running", overrides: [String: Any] = [:]) -> Data {
        // Values match the release's OrchestrationV2ThreadShellJson. Extra fields
        // include content Vorssaint must ignore rather than putting in its model.
        var thread: [String: Any] = [
            "id": "thread-1", "projectId": "project-1", "title": "Integrate T3",
            "providerInstanceId": "codex-custom", "modelSelection": ["model": "gpt-6.1-sol"],
            "status": status, "activeRunId": status == "running" ? "run-1" : NSNull(),
            "latestRunId": "run-1", "latestRunStartedAt": "2026-10-17T09:58:00Z",
            "latestRunCompletedAt": status == "completed" ? "2026-10-17T10:00:00Z" : NSNull(),
            "activityRunStatus": status == "running" ? "running" : NSNull(),
            "activityRunStartedAt": status == "running" ? "2026-10-17T09:58:00Z" : NSNull(),
            "updatedAt": "2026-10-17T10:00:00.000Z", "pendingRuntimeRequest": NSNull(),
            "pendingBackgroundTasks": [], "hasActionableProposedPlan": false,
            "latestVisibleMessage": ["text": "PRIVATE_MESSAGE_PREVIEW"]
        ]
        overrides.forEach { thread[$0.key] = $0.value }
        return try! JSONSerialization.data(withJSONObject: ["threads": [thread], "archivedThreads": [],
            "projects": [["id": "project-1", "title": "Vorssaint"]], "snapshotSequence": 12, "schemaVersion": 2])
    }

    private static func activity(_ status: String = "running", _ overrides: [String: Any] = [:]) -> [T3ThreadActivity] {
        (try! JSONDecoder().decode(T3ShellSnapshot.self, from: wire(status: status, overrides: overrides)))
            .activities(environment: identity)
    }

    private static func mapping(_ suite: TestSuite) {
        let working = activity()[0]
        suite.expect(working.state == .working && working.provider == "codex-custom" && working.model == "gpt-6.1-sol",
                     "release shell maps custom provider identity and model without a known-provider whitelist")
        suite.expect(working.id == "env-1:thread-1" && working.location == "Vorssaint · Development (dev-01)",
                     "thread identity and location stay scoped to the environment")
        suite.expect(activity("waiting", ["pendingRuntimeRequest": ["kind": "user_input"]])[0].state == .waitingForInput,
                     "a user-input request takes precedence over the run status")
        suite.expect(activity("running", ["pendingRuntimeRequest": ["kind": "command_execution_approval"]])[0].state == .waitingForApproval,
                     "a running turn with an approval request is shown as needing approval")
        suite.expect(activity("running", ["pendingRuntimeRequest": ["kind": "auth_refresh"]])[0].state == .working,
                     "internal credential refresh does not pretend to require user approval")
        suite.expect(activity("completed", ["hasActionableProposedPlan": true])[0].state == .waitingForPlan,
                     "a completed turn with an actionable plan waits for review instead of announcing completion")
        suite.expect(activity("running", ["hasActionableProposedPlan": true])[0].state == .working,
                     "a still-running plan does not request premature review")
        let limited = activity("failed", ["lastErrorClass": "usage_limit", "usageLimitResetAt": "2026-10-17T12:00:00Z"])[0]
        suite.expect(limited.state == .limited && limited.usageLimitResetAt == now.addingTimeInterval(7200),
                     "usage-limit failures retain the provider reset time")
        suite.expect(activity("running", ["lastErrorClass": "usage_limit"])[0].state == .working,
                     "a resumed run is not marked limited by an old failure")
        for kind in ["monitor", "subagent", "future-kind"] {
            suite.expect(activity("completed", ["pendingBackgroundTasks": [["taskId": "task", "kind": kind]]])[0].state == .waiting,
                         "pending \(kind) work stays visible without claiming the root agent is working")
        }
        suite.expect(activity("completed", ["pendingBackgroundTasks": [["taskId": "task", "kind": "command"]]])[0].state == .completed,
                     "a dev server left running does not hold a completed thread in waiting")
        suite.expect(activity("failed", ["lastErrorClass": "provider_error"])[0].state == .failed,
                     "ordinary provider failures remain failures")
        suite.expect(activity("completed", ["updatedAt": "bad date"]).isEmpty,
                     "an unusable timestamp cannot create a stuck activity")
    }

    private static func transitions(_ suite: TestSuite) {
        let working = activity(), completed = activity("completed")
        var reducer = T3ActivityReducer()
        suite.expect(reducer.apply(completed).isEmpty, "first snapshot never announces historical completions")
        _ = reducer.apply(working)
        let result = reducer.apply(completed)
        suite.expect(result.count == 1 && result[0].duration == 120, "an observed completion uses the released run timestamps")
        suite.expect(reducer.apply(completed).isEmpty, "repeated polling never repeats the completion notice")
        _ = reducer.apply(working)
        _ = reducer.apply([])
        suite.expect(reducer.apply(completed).isEmpty, "a disconnected activity cannot generate a guessed completion")
        _ = reducer.apply(working)
        suite.expect(reducer.apply(activity("failed")).isEmpty, "a failure never produces a success notice")
        _ = reducer.apply(working)
        suite.expect(reducer.apply(activity("completed", ["hasActionableProposedPlan": true])).isEmpty,
                     "plan review never produces a success notice")
    }

    private static func presentation(_ suite: TestSuite) {
        let working = activity()[0]
        let input = activity("waiting", ["pendingRuntimeRequest": ["kind": "user_input"]])[0]
        let waiting = activity("waiting")[0]
        let completed = activity("completed")[0]
        suite.expect(T3ActivityPresentation.workingCount([working, waiting, input]) == 1,
                     "waiting and input requests are excluded from the working count")
        suite.expect(T3ActivityPresentation.compactSummary([input, working, completed], now: now)?.state == .waitingForInput,
                     "a question remains visible when another task finishes")
        suite.expect(!T3ActivityPresentation.allowsCompletionNotice([input, completed]),
                     "a completion notice cannot obscure an input request")
        suite.expect(T3ActivityPresentation.compactSummary([completed], now: now)?.state == .completed
                        && T3ActivityPresentation.compactSummary([completed], now: now.addingTimeInterval(5)) == nil,
                     "a completion-only strip leaves after five seconds")
        suite.expect(T3ActivityPresentation.compactSummary([working, waiting], now: now)?.workingCount == 1,
                     "ordinary background waiting does not hide active work")
        suite.expect(T3ActivityPresentation.visible([completed], now: now.addingTimeInterval(600)).isEmpty,
                     "terminal rows expire without a new thread event")
        var remote = working
        // Identical thread ids on two environments are distinct; retries from one are not.
        remote = T3ThreadActivity(id: "env-2:thread-1", threadID: remote.threadID, environmentID: "env-2",
            environment: "Remote", machine: nil, project: remote.project, title: remote.title, provider: remote.provider,
            model: remote.model, state: .working, startedAt: now, completedAt: nil, updatedAt: now,
            latestRunID: "run-1", latestRunStartedAt: now, latestRunWorkStartedAt: nil,
            activityRunID: "run-1", activityRunStartedAt: now, backgroundTaskCount: 0)
        suite.expect(T3ActivityAggregator.merge(["one": [working], "retry": [working], "two": [remote]]).count == 2,
                     "aggregation deduplicates within an environment without merging different machines")
    }

    private static func configuration(_ suite: TestSuite) {
        let name = "vorssaint.tests.t3-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = T3ConfiguredConnectionStore(defaults: defaults)
        let connection = T3ConfiguredConnection(id: "connection", endpoint: "https://dev.example.test",
            environmentID: "env-1", label: "Development", machine: "dev-01", credentialID: "keychain-reference",
            expiresAt: now.addingTimeInterval(7200))
        store.save([connection, connection])
        suite.expect(store.load() == [connection], "only one connection is saved for an environment")
        suite.expect(SettingsBackupSupport.machineStateKeys.contains(DefaultsKey.notchAgentsT3Connections),
                     "device-bound T3 connections are excluded from settings export")
        defaults.set(Data("corrupt".utf8), forKey: DefaultsKey.notchAgentsT3Connections)
        suite.expect(store.load().isEmpty, "damaged connection metadata does not start network activity")
        suite.expect(T3KeychainCredentialStore.account(endpoint: URL(string: connection.endpoint)!, environmentID: "one")
                        != T3KeychainCredentialStore.account(endpoint: URL(string: connection.endpoint)!, environmentID: "two"),
                     "Keychain bindings distinguish environments at the same address")
    }

    @MainActor private static func expiry(_ suite: TestSuite) {
        var scheduled: (@MainActor () -> Void)?
        var cancellations = 0, expirations = 0, current = true
        let controller = T3ActivityExpiryController { delay, action in
            suite.expect(delay == 7, "activity expires ten seconds after the last successful poll")
            scheduled = action
            return { cancellations += 1 }
        }
        controller.recordSuccess(connectionID: "one", at: now)
        controller.expireAfterTransientFailure(connectionID: "one", now: now.addingTimeInterval(3),
            isGenerationCurrent: { current }, onExpire: { expirations += 1 })
        scheduled?()
        suite.expect(expirations == 1, "a stalled network request cannot leave the last activity working forever")
        controller.recordSuccess(connectionID: "one", at: now)
        controller.expireAfterTransientFailure(connectionID: "one", now: now.addingTimeInterval(3),
            isGenerationCurrent: { current }, onExpire: { expirations += 1 })
        let old = scheduled
        controller.recordSuccess(connectionID: "one", at: now.addingTimeInterval(4))
        old?()
        suite.expect(expirations == 1 && cancellations > 0, "recovery cancels a pending activity expiry")
        current = false
        controller.expireAfterTransientFailure(connectionID: "one", now: now.addingTimeInterval(7),
            isGenerationCurrent: { current }, onExpire: { expirations += 1 })
        scheduled?()
        suite.expect(expirations == 1, "a stale polling generation cannot expire a replacement connection")
        controller.cancelAll()
    }

    private static func client(_ suite: TestSuite) async {
        let transport = T3FixtureTransport(shell: wire())
        let client = T3CodeClient(transport: transport)
        for endpoint in ["http://127.0.0.1:3773", "http://[::1]:3773", "https://dev.example.test"] {
            suite.expect((try? client.validateEndpoint(endpoint)) != nil, "trusted transport accepted: \(endpoint)")
        }
        for endpoint in ["http://dev.example.test", "https://user:pass@dev.example.test", "https://dev.example.test/path",
                         "https://dev.example.test?token=secret", "file:///tmp/t3"] {
            suite.expect((try? client.validateEndpoint(endpoint)) == nil, "unsafe or ambiguous endpoint rejected")
        }
        do {
            let endpoint = URL(string: "https://dev.example.test")!
            let (identity, token, _) = try await client.pair(endpoint: endpoint, credential: "test-pairing-code")
            _ = try await client.fetchSnapshot(endpoint: endpoint, token: token, expectedEnvironmentID: identity.id)
            let requests = transport.requests
            let exchange = requests.first { $0.url?.path == "/oauth/token" }!
            suite.expect(String(data: exchange.httpBody!, encoding: .utf8)!.contains("scope=orchestration%3Aread"),
                         "pairing explicitly narrows the grant to read-only orchestration")
            let snapshot = requests.last!
            suite.expect(snapshot.httpMethod == "GET" && snapshot.value(forHTTPHeaderField: "x-t3-orchestration-protocol") == "2",
                         "thread activity uses the release's read endpoint and protocol header")
            for (status, expected): (Int, T3CodeConnectionError) in [
                (401, .authenticationExpired), (403, .readPermissionMissing), (503, .serverUnavailable)
            ] {
                transport.shellStatus = status
                do {
                    _ = try await client.fetchSnapshot(endpoint: endpoint, token: token)
                    suite.expect(false, "HTTP \(status) must fail at its correct boundary")
                } catch {
                    suite.expect(error as? T3CodeConnectionError == expected,
                                 "HTTP \(status) distinguishes authentication, permission and transient failure")
                }
            }
            transport.shellStatus = 200
            transport.identity = "different-environment"
            let before = transport.requests.filter { $0.url?.path == "/api/orchestration/shell" }.count
            do {
                _ = try await client.fetchSnapshot(endpoint: endpoint, token: token, expectedEnvironmentID: identity.id)
                suite.expect(false, "a changed environment identity must fail")
            } catch {
                suite.expect(transport.requests.filter { $0.url?.path == "/api/orchestration/shell" }.count == before,
                             "no bearer credential is sent to an address now serving another environment")
            }
            transport.scope = "orchestration:read orchestration:operate"
            do {
                _ = try await client.pair(endpoint: endpoint, credential: "test-pairing-code")
                suite.expect(false, "an overprivileged token must be rejected")
            } catch { suite.expect(error as? T3CodeConnectionError == .readPermissionMissing, "broader grants are rejected") }
        } catch { suite.expect(false, "T3 contract fixture failed: \(error)") }
    }
}

private final class T3FixtureTransport: T3CodeHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    var identity = "env-1"
    var scope = "orchestration:read"
    var shellStatus = 200
    let shell: Data
    init(shell: Data) { self.shell = shell }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }
        let data: Data
        switch request.url!.path {
        case "/.well-known/t3/environment":
            data = try JSONSerialization.data(withJSONObject: ["environmentId": identity, "label": "Development",
                "platform": ["machine": "dev-01"], "orchestrationProtocolVersion": 2])
        case "/oauth/token":
            data = try JSONSerialization.data(withJSONObject: ["access_token": "fixture-token", "token_type": "Bearer",
                "issued_token_type": "urn:ietf:params:oauth:token-type:access_token", "expires_in": 3600, "scope": scope])
        default: data = shell
        }
        let status = request.url!.path == "/api/orchestration/shell" ? shellStatus : 200
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Opt-in acceptance talks to a real environment; no credentials or thread
/// content are logged. The temporary Keychain item is removed on every exit.
enum T3CodeLiveAcceptance {
    static func run(endpoint: String, pairingCode: String, suite: TestSuite) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            do {
                let client = T3CodeClient()
                let origin = try client.validateEndpoint(endpoint)
                let (identity, token, _) = try await client.pair(endpoint: origin, credential: pairingCode)
                let credentials = T3KeychainCredentialStore()
                let account = T3KeychainCredentialStore.account(endpoint: origin, environmentID: identity.id,
                                                                credentialID: UUID().uuidString)
                defer { credentials.remove(account: account) }
                suite.expect(credentials.write(token, account: account), "live read grant saves to Keychain")
                suite.expect(credentials.read(account: account) == .found(token), "live read grant reloads from Keychain")
                let snapshot = try await client.fetchSnapshot(endpoint: origin, token: token,
                                                              expectedEnvironmentID: identity.id)
                let activities = snapshot.activities(environment: identity)
                suite.expect(!activities.isEmpty, "real shell decodes through the production client")
                suite.expect(activities.allSatisfy { !$0.environment.isEmpty && !$0.provider.isEmpty },
                             "real activity carries environment and provider identities")
                print("LIVE T3: \(activities.count) threads; \(activities.filter { $0.state == .working }.count) working; environment \(identity.label)")
            } catch { suite.expect(false, "live T3 acceptance failed: \(error)") }
        }
        suite.expect(done.wait(timeout: .now() + 45) == .success, "live acceptance completes within 45 seconds")
    }
}

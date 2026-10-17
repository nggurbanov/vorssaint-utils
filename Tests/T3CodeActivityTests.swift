// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Lifecycle cases informed by Bruno Hjorth (liltaket), PR #2747.

import Foundation
import SQLite3

/// Contract checks target the v0.1.0 wire schema, not a copied provider log.
enum T3CodeActivityTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-10-17T10:00:00Z")!
    private static let identity = T3EnvironmentIdentity(id: "env-1", label: "Development", machine: "dev-01")

    static func run(_ suite: TestSuite) {
        T3ConnectTests.run(suite)
        T3AgentNoticeTests.run(suite)
        mapping(suite)
        transitions(suite)
        presentation(suite)
        configuration(suite)
        localNames(suite)
        usage(suite)
        MainActor.assumeIsolated { expiry(suite) }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await client(suite)
            done.signal()
        }
        suite.expect(done.wait(timeout: .now() + 10) == .success, "T3 transport checks finish within a bounded timeout")
        for language in AppLanguage.allCases {
            let strings = T3CodeStrings(language)
            suite.expect(!strings.usageEstimates.isEmpty, "T3 usage coverage is explained in \(language)")
            for state: T3ThreadState in [.working, .waiting, .waitingForInput, .waitingForApproval, .waitingForPlan,
                                         .limited, .idle, .completed, .failed, .stopped] {
                suite.expect(!strings.stateText(state).isEmpty, "T3 state has a label in \(language)")
            }
        }
    }

    private static func usageWire(overrides: [String: Any] = [:], threadID: String = "thread-1") -> Data {
        var turn: [String: Any] = [
            "id": "turn-1", "providerThreadId": "pt-1", "nodeId": "node-1", "runAttemptId": "attempt-1",
            "nativeTurnRef": ["nativeId": "native-turn-1", "strength": "strong"],
            "startedAt": "2026-10-17T09:58:00Z", "completedAt": "2026-10-17T10:00:00Z",
            "turnTokenUsage": ["usageStatus": "complete", "usageScope": "main_agent", "hasSubagents": false,
                               "inputTokens": 10000, "cachedInputTokens": 8000, "cacheCreationTokens": 500,
                               "outputTokens": 1000, "reasoningTokens": 100],
            "tokenUsage": ["usedTokens": 9999999]
        ]
        overrides.forEach { turn[$0.key] = $0.value }
        return try! JSONSerialization.data(withJSONObject: ["projection": [
            "thread": ["id": threadID, "projectId": "project-1"],
            "runs": [["id": "run-1", "modelSelection": ["model": "gpt-6-sol"]]],
            "attempts": [["id": "attempt-1", "runId": "run-1"]],
            "nodes": [["id": "node-1", "runId": "run-1"]],
            "providerThreads": [["id": "pt-1", "driver": "codex",
                "nativeThreadRef": ["nativeId": "native-session-1", "strength": "strong"]]],
            "providerTurns": [turn], "messages": [["text": "PRIVATE_TRANSCRIPT_MUST_BE_IGNORED"]],
            "turnItems": [["toolOutput": "PRIVATE_TOOL_OUTPUT"]]
        ]])
    }

    private static func usage(_ suite: TestSuite) {
        let oldPrices = AgentPricing.list
        defer { AgentPricing.install(oldPrices) }
        AgentPricing.install(AgentPriceList(updated: now, claude: [],
            codex: [.init(id: "gpt-6-sol", price: AgentPrice(input: 2, output: 8, cacheRead: 0.2, cacheWrite: 3, cacheWriteLong: 4))],
            claudePlans: [], codexPlans: [], webSearch: 0, usOnlyMultiplier: 1))
        func report(_ overrides: [String: Any] = [:]) -> T3UsageReport {
            (try! JSONDecoder().decode(T3UsageThreadSnapshot.self, from: usageWire(overrides: overrides)))
                .report(environmentID: "remote-1", projectTitle: "Remote project")
        }
        let usage = report()
        let sample = usage.samples[0]
        suite.expect(sample.tokens == AgentTokens(input: 1500, cacheWrite: 500, cacheRead: 8000, output: 1000, reasoning: 100),
                     "T3 billed input excludes disjoint cache categories and reasoning stays inside output")
        suite.expect(sample.tokens.total == 11000 && abs(sample.record.cost! - 0.0141) < 0.0000001,
                     "T3 uses existing model pricing for API value, not context-window counters or an invoice")
        suite.expect(sample.record.requests == 0, "a T3 turn does not fabricate the number of model responses")
        suite.expect(sample.project.id == "t3:remote-1:project-1" && sample.project.name == "Remote project",
                     "per-turn tokens retain T3 project identity and title")
        let localRecord = AgentUsageRecord(provider: .codex, date: now, model: "gpt-6-sol", project: "Native project",
            session: "local-1", tokens: AgentTokens(input: 20, output: 5), cost: 0.25, savings: 0)
        let local = AgentUsageSummary.snapshot(records: [localRecord], limits: [:], live: [], plans: [:], providers: [.codex], now: now)
        let combined = usage.adding(to: local, localSessions: [], providers: [.codex])
        suite.expect(combined.usage(.today).total.tokens.total == local.usage(.today).total.tokens.total + 11000
                     && combined.usage(.today).projects.contains { $0.id == sample.project.id },
                     "remote turns populate existing spending and project breakdowns")
        suite.expect(combined.days.last!.total.tokens.total == combined.usage(.today).total.tokens.total
                     && combined.hours.reduce(0) { $0 + $1.total.tokens.total } == combined.usage(.today).total.tokens.total,
                     "remote usage also populates trends, hourly history and activity buckets")
        suite.expect(usage.adding(to: local, localSessions: ["codex:native-session-1"], providers: [.codex]) == local,
                     "native response logs take precedence over overlapping T3 per-turn totals")
        suite.expect(T3UsageReport.merge([usage, usage]).samples.count == 1,
                     "a physical native turn seen through multiple connections counts once")
        suite.expect(usage.adding(to: local, localSessions: [], providers: [.claude]).usage(.today).total == local.usage(.today).total,
                     "remote usage honors provider visibility settings")
        suite.expect(report(["turnTokenUsage": NSNull()]).samples.isEmpty && report(["turnTokenUsage": NSNull()]).missingTurns == 1,
                     "context-window usage never substitutes for missing billed turn counters")
        let incomplete: [String: Any] = ["usageStatus": "partial", "usageScope": "main_agent", "hasSubagents": true,
                                        "inputTokens": 100, "outputTokens": 10]
        suite.expect(report(["turnTokenUsage": incomplete]).partialTurns == 1,
                     "partial counters and missing subagent coverage stay marked incomplete")
        var invalid = incomplete
        invalid["cachedInputTokens"] = 101
        suite.expect(report(["turnTokenUsage": invalid]).samples.isEmpty,
                     "inconsistent cache counters are excluded instead of overcounted")
        suite.expect(report(["nativeTurnRef": ["nativeId": "unreliable", "strength": "weak"]]).samples.isEmpty,
                     "turns without strong native identities cannot silently double count")
    }

    private static func localNames(_ suite: TestSuite) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("metadata.sqlite")
        var db: OpaquePointer?
        suite.expect(sqlite3_open(database.path, &db) == SQLITE_OK, "T3 names fixture opens")
        defer { sqlite3_close(db) }
        let setup = """
            CREATE TABLE projection_projects (project_id TEXT, title TEXT, deleted_at TEXT);
            CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT, project_id TEXT, title TEXT, deleted_at TEXT);
            CREATE TABLE orchestration_v2_projection_provider_threads (thread_id TEXT, driver TEXT, payload_json TEXT);
            INSERT INTO projection_projects VALUES ('project-1', 'Vorssaint', NULL);
            INSERT INTO orchestration_v2_projection_threads VALUES ('thread-1', 'project-1', 'Integrate T3', NULL);
            INSERT INTO orchestration_v2_projection_provider_threads VALUES ('thread-1', 'codex',
                '{"nativeThreadRef":{"nativeId":"native-1","strength":"strong"}}');
            INSERT INTO orchestration_v2_projection_provider_threads VALUES ('thread-1', 'claude',
                '{"nativeThreadRef":{"nativeId":"native-1","strength":"strong"}}');
            INSERT INTO orchestration_v2_projection_provider_threads VALUES ('thread-1', 'codex',
                '{"nativeThreadRef":{"nativeId":"weak-1","strength":"weak"}}');
            """
        suite.expect(sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK, "T3 metadata-only fixture is valid")
        let metadata = T3LocalMetadata.read(database: database)
        suite.expect(metadata.sessions.count == 2 && metadata.liveTitle(provider: .codex, nativeID: "native-1") == "Integrate T3",
                     "native IDs resolve T3 conversation titles without credentials or transcript tables")
        suite.expect(metadata.session(provider: .codex, nativeID: "native-1")?.project.name == "Vorssaint",
                     "usage attribution uses the T3 project title, separately from the conversation title")
        suite.expect(metadata.session(provider: .codex, nativeID: "weak-1") == nil,
                     "weak references never relabel an unrelated native session")
        let records = [AgentUsageRecord(provider: .codex, date: now, model: "gpt-6-sol", project: "2026-10-17-weird-slug",
                                       session: "native-1", tokens: AgentTokens(input: 100, output: 20), cost: 0.5, savings: 0.1),
                       AgentUsageRecord(provider: .codex, date: now, model: "gpt-6-sol", project: "2026-10-17-weird-slug",
                                       session: "unrelated", tokens: AgentTokens(input: 40, output: 10), cost: 0.2, savings: 0)]
        let cache = AgentUsageSummaryCache()
        func snapshot(_ metadata: T3LocalMetadata) -> AgentUsageSnapshot {
            cache.snapshot(records: records, limits: [:], live: [], plans: [:], providers: [.codex], now: now,
                           projectsBySession: metadata.projectsBySession)
        }
        let raw = snapshot(T3LocalMetadata())
        let named = snapshot(metadata)
        suite.expect(named.usage(.today).projects.contains { $0.name == "Vorssaint" && $0.totals.cost == 0.5 },
                     "historical Projects attributes existing usage to the real T3 project")
        suite.expect(named.usage(.today).projects.contains { $0.name == "2026-10-17-weird-slug" && $0.totals.cost == 0.2 },
                     "an unrelated session in the same folder keeps its original attribution")
        suite.expect(named.usage(.today).total == raw.usage(.today).total && named.days == raw.days && named.hours == raw.hours,
                     "T3 names preserve spending, tokens, trend buckets and response counts without importing duplicates")
        _ = snapshot(metadata)
        suite.expect(cache.accumulatedRecords == 0, "unchanged T3 names preserve incremental summary caching")
        suite.expect(sqlite3_exec(db, "UPDATE projection_projects SET title = 'Renamed project'; UPDATE orchestration_v2_projection_threads SET title = 'Renamed conversation'", nil, nil, nil) == SQLITE_OK,
                     "T3 fixture can rename projects and conversations")
        let renamed = T3LocalMetadata.read(database: database)
        let afterRename = snapshot(renamed)
        suite.expect(afterRename.usage(.today).projects.contains { $0.id == "t3-local:project-1" && $0.name == "Renamed project" },
                     "renaming T3 rebuilds historical attribution without changing project identity")
        suite.expect(renamed.liveTitle(provider: .codex, nativeID: "native-1") == "Renamed conversation",
                     "conversation titles follow T3 renames")
        suite.expect(snapshot(T3LocalMetadata()).usage(.today).projects == raw.usage(.today).projects,
                     "unavailable metadata falls back to original names without modifying stored usage")
        suite.expect(sqlite3_exec(db, "INSERT INTO orchestration_v2_projection_threads VALUES ('thread-2', 'project-1', 'Different owner', NULL); INSERT INTO orchestration_v2_projection_provider_threads SELECT 'thread-2', driver, payload_json FROM orchestration_v2_projection_provider_threads WHERE driver = 'codex'", nil, nil, nil) == SQLITE_OK,
                     "T3 ambiguity fixture is valid")
        let ambiguous = T3LocalMetadata.read(database: database)
        suite.expect(ambiguous.session(provider: .codex, nativeID: "native-1") == nil
                     && ambiguous.session(provider: .claude, nativeID: "native-1") != nil,
                     "ambiguous native ownership is ignored and provider IDs remain isolated")
        let missing = directory.appendingPathComponent("missing.sqlite")
        suite.expect(T3LocalMetadata.read(database: missing).sessions.isEmpty && !FileManager.default.fileExists(atPath: missing.path),
                     "read-only discovery never creates a T3 database")

        // Exercise the extracted production service read method, not a copy of
        // completion-notice attribution logic.
        let host = AgentUsageReadTests.Host()
        host.t3Metadata = metadata
        host.store.reportsTransitions = true
        let log = directory.appendingPathComponent("codex.jsonl")
        let timestamp = Date().timeIntervalSince1970
        let lines = [
            #"{"type":"session_meta","timestamp":\#(timestamp - 20),"payload":{"id":"native-1","cwd":"/tmp/weird-slug"}}"#,
            #"{"type":"turn_context","timestamp":\#(timestamp - 20),"payload":{"model":"gpt-6-sol","cwd":"/tmp/weird-slug"}}"#,
            #"{"type":"event_msg","timestamp":\#(timestamp - 20),"payload":{"type":"task_started"}}"#,
            #"{"type":"token_usage_record","timestamp":\#(timestamp - 1),"payload":{"response_id":"r","usage":{"input_tokens":100,"output_tokens":20}}}"#,
            #"{"type":"event_msg","timestamp":\#(timestamp),"payload":{"type":"task_complete","duration_ms":20000}}"#
        ]
        try! Data((lines.joined(separator: "\n") + "\n").utf8).write(to: log)
        host.read(log.path, provider: .codex)
        suite.expect(host.events.contains { event in
            if case .finished(.codex, _, _, 120, "Integrate T3") = event { return true }
            return false
        }, "production completion delivery replaces the scratch slug with the T3 conversation title")

        if ProcessInfo.processInfo.environment["VORSS_T3_METADATA_ACCEPTANCE"] == "1" {
            let real = T3LocalMetadata.read(home: FileManager.default.homeDirectoryForCurrentUser)
            suite.expect(!real.sessions.isEmpty, "the production metadata reader joins real T3 session/project titles")
            print("T3 local metadata acceptance: \(real.sessions.count) provider/session identities; no credentials read")
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
            transport.usageData = usageWire()
            let usage = try await client.fetchUsageThread(endpoint: endpoint, token: token, threadID: "thread-1")
            suite.expect(usage.report(environmentID: identity.id, projectTitle: "Test").samples.count == 1,
                         "production HTTP client decodes per-turn usage with the existing read-only credential")
            suite.expect(transport.requests.last!.httpMethod == "GET"
                         && transport.requests.last!.value(forHTTPHeaderField: "x-t3-orchestration-protocol") == "2",
                         "usage reads neither mutate T3 nor request broader scopes")
            let proofKey = T3DPoPKey()
            transport.tokenType = "DPoP"
            let (_, boundToken, _) = try await client.pair(endpoint: endpoint, credential: "proof-bootstrap",
                proofKey: proofKey, expectedEnvironmentID: identity.id)
            let boundExchange = transport.requests.last!
            suite.expect(boundExchange.value(forHTTPHeaderField: "DPoP") != nil,
                         "environment exchange proves possession of the bootstrap-bound key")
            _ = try await client.fetchSnapshot(endpoint: endpoint, token: boundToken, proofKey: proofKey)
            _ = try await client.fetchUsageThread(endpoint: endpoint, token: boundToken, threadID: "thread-1", proofKey: proofKey)
            let boundReads = transport.requests.suffix(2)
            suite.expect(boundReads.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "DPoP fixture-token"
                && $0.value(forHTTPHeaderField: "DPoP") != nil }, "bound activity and spending reads both carry fresh proofs")
            suite.expect(boundReads.first!.value(forHTTPHeaderField: "DPoP") != boundReads.last!.value(forHTTPHeaderField: "DPoP"),
                         "proofs are unique for each environment request")
            transport.tokenType = "Bearer"
            do {
                _ = try await client.pair(endpoint: endpoint, credential: "proof-bootstrap", proofKey: proofKey)
                suite.expect(false, "proof-bound pairing must reject a bearer downgrade")
            } catch { suite.expect(error as? T3CodeConnectionError == .readPermissionMissing, "Connect cannot silently downgrade to bearer access") }
            let exchangesBefore = transport.requests.filter { $0.url?.path == "/oauth/token" }.count
            do {
                _ = try await client.pair(endpoint: endpoint, credential: "proof-bootstrap", proofKey: proofKey,
                                          expectedEnvironmentID: "wrong-environment")
                suite.expect(false, "Connect pairing must check the expected environment first")
            } catch {
                suite.expect(transport.requests.filter { $0.url?.path == "/oauth/token" }.count == exchangesBefore,
                             "Connect never sends a bootstrap credential to another environment")
            }
            transport.usageData = usageWire(threadID: "different-thread")
            do {
                _ = try await client.fetchUsageThread(endpoint: endpoint, token: token, threadID: "thread-1")
                suite.expect(false, "usage for a different thread must be rejected")
            } catch { suite.expect(error as? T3CodeConnectionError == .invalidResponse, "usage validates returned thread identity") }
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
    var tokenType = "Bearer"
    var shellStatus = 200
    var usageData: Data?
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
            data = try JSONSerialization.data(withJSONObject: ["access_token": "fixture-token", "token_type": tokenType,
                "issued_token_type": "urn:ietf:params:oauth:token-type:access_token", "expires_in": 3600, "scope": scope])
        default: data = request.url!.path.hasPrefix("/api/orchestration/threads/") ? usageData ?? shell : shell
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
                let proofKey = ProcessInfo.processInfo.environment["VORSSAINT_T3_DPOP"] == "1" ? T3DPoPKey() : nil
                let (identity, token, _) = try await client.pair(endpoint: origin, credential: pairingCode, proofKey: proofKey)
                let credentials = T3KeychainCredentialStore()
                let account = T3KeychainCredentialStore.account(endpoint: origin, environmentID: identity.id,
                                                                credentialID: UUID().uuidString)
                defer { credentials.remove(account: account) }
                suite.expect(credentials.write(token, account: account), "live read grant saves to Keychain")
                suite.expect(credentials.read(account: account) == .found(token), "live read grant reloads from Keychain")
                let snapshot = try await client.fetchSnapshot(endpoint: origin, token: token,
                                                              expectedEnvironmentID: identity.id, proofKey: proofKey)
                let activities = snapshot.activities(environment: identity)
                suite.expect(!activities.isEmpty, "real shell decodes through the production client")
                suite.expect(activities.allSatisfy { !$0.environment.isEmpty && !$0.provider.isEmpty },
                             "real activity carries environment and provider identities")
                print("LIVE T3: \(activities.count) threads; \(activities.filter { $0.state == .working }.count) working; environment \(identity.label)")
                if let thread = activities.first(where: { $0.provider.lowercased().contains("codex") && $0.latestRunID != nil }) {
                    let detail = try await client.fetchUsageThread(endpoint: origin, token: token, threadID: thread.threadID, proofKey: proofKey)
                    let report = detail.report(environmentID: identity.id, projectTitle: thread.project)
                    suite.expect(!report.samples.isEmpty, "real read-only thread API provides attributable per-turn tokens")
                    suite.expect(report.samples.allSatisfy { !$0.project.name.isEmpty && $0.nativeSession != nil },
                                 "real remote token records retain project titles and native identities")
                    print("LIVE T3 USAGE: \(report.samples.count) turns; \(report.missingTurns) missing; \(report.partialTurns) partial")
                }
            } catch { suite.expect(false, "live T3 acceptance failed: \(error)") }
        }
        suite.expect(done.wait(timeout: .now() + 45) == .success, "live acceptance completes within 45 seconds")
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Deliberately ignores conversation text, tool output and files in the wire
/// projection. Context-window `tokenUsage` is not billed usage and is ignored.
struct T3UsageThreadSnapshot: Decodable {
    let projection: Projection

    struct Projection: Decodable {
        let thread: Thread
        let runs: [Run]
        let attempts: [Attempt]
        let nodes: [Node]
        let providerThreads: [ProviderThread]
        let providerTurns: [Turn]
    }
    struct Thread: Decodable { let id: String; let projectId: String }
    struct Run: Decodable { let id: String; let modelSelection: ModelSelection }
    struct ModelSelection: Decodable { let model: String? }
    struct Attempt: Decodable { let id: String; let runId: String }
    struct Node: Decodable { let id: String; let runId: String? }
    struct NativeRef: Decodable { let nativeId: String; let strength: String }
    struct ProviderThread: Decodable {
        let id: String
        let driver: String
        let nativeThreadRef: NativeRef?
    }
    struct Turn: Decodable {
        let id: String
        let providerThreadId: String
        let nodeId: String
        let runAttemptId: String?
        let nativeTurnRef: NativeRef?
        let startedAt: String?
        let completedAt: String?
        let turnTokenUsage: Usage?
    }
    struct Usage: Decodable {
        let usageStatus: String
        let usageScope: String
        let hasSubagents: Bool
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let cacheCreationTokens: Int?
        let outputTokens: Int?
        let reasoningTokens: Int?
    }

    func report(environmentID: String, projectTitle: String) -> T3UsageReport {
        let data = projection
        var result = T3UsageReport()
        let providers = Dictionary(data.providerThreads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let runs = Dictionary(data.runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let attempts = Dictionary(data.attempts.map { ($0.id, $0.runId) }, uniquingKeysWith: { a, _ in a })
        let nodes = Dictionary(data.nodes.compactMap { node in node.runId.map { (node.id, $0) } }, uniquingKeysWith: { a, _ in a })
        for turn in data.providerTurns {
            guard let providerThread = providers[turn.providerThreadId],
                  let provider = AgentProvider(rawValue: providerThread.driver),
                  let usage = turn.turnTokenUsage, usage.usageScope == "main_agent",
                  usage.usageStatus != "unavailable",
                  let input = usage.inputTokens, let output = usage.outputTokens,
                  let date = (turn.completedAt ?? turn.startedAt).flatMap(T3ShellSnapshot.date),
                  input >= 0, output >= 0 else { result.missingTurns += 1; continue }
            let cached = usage.cachedInputTokens ?? 0
            let written = usage.cacheCreationTokens ?? 0
            let reasoning = usage.reasoningTokens ?? 0
            guard cached >= 0, written >= 0, reasoning >= 0,
                  cached <= input, written <= input - cached, reasoning <= output else {
                result.missingTurns += 1
                continue
            }
            let nativeSession = providerThread.nativeThreadRef.flatMap { $0.strength == "strong" ? $0.nativeId : nil }
            let nativeTurn = turn.nativeTurnRef.flatMap { $0.strength == "strong" ? $0.nativeId : nil }
            guard let nativeSession, !nativeSession.isEmpty, let nativeTurn, !nativeTurn.isEmpty else {
                result.missingTurns += 1
                continue
            }
            // Strong native identities deduplicate the same physical turn seen
            // through another app thread or paired environment.
            let id = "\(provider.rawValue):\(nativeSession):\(nativeTurn)"
            let runID = turn.runAttemptId.flatMap { attempts[$0] } ?? nodes[turn.nodeId]
            let model = runID.flatMap { runs[$0]?.modelSelection.model } ?? ""
            let partial = usage.usageStatus != "complete" || usage.hasSubagents || model.isEmpty
            if partial { result.partialTurns += 1 }
            result.samples.append(T3UsageSample(id: id, provider: provider, nativeSession: nativeSession,
                date: date, model: model,
                project: AgentProjectIdentity(id: "t3:\(environmentID):\(data.thread.projectId)", name: projectTitle),
                tokens: AgentTokens(input: input - cached - written, cacheWrite: written,
                                    cacheRead: cached, output: output, reasoning: reasoning), partial: partial))
        }
        return result
    }
}

struct T3UsageSample: Equatable {
    let id: String
    let provider: AgentProvider
    let nativeSession: String?
    let date: Date
    let model: String
    var project: AgentProjectIdentity
    let tokens: AgentTokens
    let partial: Bool

    var nativeSessionKey: String? {
        nativeSession.map { AgentProjectIdentity.sessionKey(provider: provider, session: $0) }
    }

    var record: AgentUsageRecord {
        let price = AgentPricing.cost(AgentBillable(tokens: tokens, isAggregate: true), model: model)
        // A provider turn can contain several model responses; do not invent
        // a response count. These are per-turn API-value estimates.
        return AgentUsageRecord(provider: provider, date: date, model: model, project: project.name,
            session: id, requests: 0, tokens: tokens, cost: price.cost, savings: price.savings)
    }
}

struct T3UsageReport: Equatable {
    var samples: [T3UsageSample] = []
    var missingTurns = 0
    var partialTurns = 0
    var pendingThreads = 0

    static func merge(_ reports: [T3UsageReport]) -> T3UsageReport {
        var result = T3UsageReport()
        var samples: [String: T3UsageSample] = [:]
        for report in reports {
            result.missingTurns += report.missingTurns
            result.partialTurns += report.partialTurns
            result.pendingThreads += report.pendingThreads
            for sample in report.samples {
                if let old = samples[sample.id], !old.partial { continue }
                samples[sample.id] = sample
            }
        }
        result.samples = samples.values.sorted { $0.id < $1.id }
        return result
    }

    func adding(to local: AgentUsageSnapshot, localSessions: Set<String>, providers: Set<AgentProvider>) -> AgentUsageSnapshot {
        let samples = samples.filter { sample in
            // Prefer precise native response records whenever this Mac already
            // reads that session. Never add a T3 aggregate on top of it.
            sample.nativeSessionKey.map { !localSessions.contains($0) } ?? true
        }
        guard !samples.isEmpty else { return local }
        let names = Dictionary(samples.map { (AgentProjectIdentity.sessionKey(provider: $0.provider, session: $0.id), $0.project) },
                               uniquingKeysWith: { first, _ in first })
        let remote = AgentUsageSummary.snapshot(records: samples.map(\.record), limits: [:], live: [], plans: [:],
            providers: providers, now: local.now, projectsBySession: names)
        var result = local
        for period in AgentPeriod.allCases {
            var usage = result.usage(period)
            let other = remote.usage(period)
            usage.total += other.total
            for (provider, total) in other.byProvider { usage.byProvider[provider, default: AgentTotals()] += total }
            usage.models = Self.shares(usage.models, other.models, byCost: usage.fullyPriced)
            usage.projects = Self.shares(usage.projects, other.projects, byCost: usage.fullyPriced)
            result.periods[period] = usage
        }
        result.days = Self.buckets(result.days, remote.days)
        result.hours = Self.buckets(result.hours, remote.hours)
        for (provider, rate) in remote.burnRate { result.burnRate[provider, default: AgentTotals()] += rate }
        for (provider, date) in remote.lastActivity { result.lastActivity[provider] = max(result.lastActivity[provider] ?? .distantPast, date) }
        result.seen.formUnion(remote.seen)
        return result
    }

    private static func shares(_ first: [AgentShare], _ second: [AgentShare], byCost: Bool) -> [AgentShare] {
        var shares = Dictionary(first.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for share in second {
            if shares[share.id] == nil { shares[share.id] = share }
            else { shares[share.id]!.totals += share.totals }
        }
        return AgentUsageSummary.sorted(Array(shares.values), byCost: byCost)
    }

    private static func buckets(_ first: [AgentBucket], _ second: [AgentBucket]) -> [AgentBucket] {
        let other = Dictionary(second.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
        return first.map { bucket in
            var bucket = bucket
            for (provider, total) in other[bucket.start]?.byProvider ?? [:] {
                bucket.byProvider[provider, default: AgentTotals()] += total
            }
            return bucket
        }
    }
}

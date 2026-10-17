// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Run the actual island delivery method against an event recorder. A local
/// completion must not cover a remote question, approval, or plan review.
enum T3AgentNoticeTests {
    enum L10n {
        struct Reading { let language = AppLanguage.enUS }
        static let shared = Reading()
    }
    final class Remote {
        var activities: [T3ThreadActivity] = []
    }
    enum T3CodeActivityService {
        static let shared = Remote()
    }
    class Fixture {
        var notices: [NotchNotice] = []
        func show(_ notice: NotchNotice) { notices.append(notice) }
        func reactMascot(_ reaction: NotchMascotReaction) {}
    }

    static func run(_ suite: TestSuite) {
        let remote = T3CodeActivityService.shared
        defer { remote.activities = [] }
        let finished = AgentUsageEvent.finished(provider: .codex, duration: 90, cost: 0, tokens: 0, project: "local")
        for state: T3ThreadState in [.waitingForInput, .waitingForApproval, .waitingForPlan] {
            let now = Date()
            remote.activities = [T3ThreadActivity(id: "remote:thread", threadID: "thread", environmentID: "remote",
                environment: "Development", machine: nil, project: "test", title: "Needs attention", provider: "codex",
                model: "model", state: state, startedAt: now, completedAt: nil, updatedAt: now,
                latestRunID: "run", latestRunStartedAt: now, latestRunWorkStartedAt: nil,
                activityRunID: "run", activityRunStartedAt: now, backgroundTaskCount: 0)]
            let host = Host()
            host.showAgentEvent(finished)
            suite.expect(host.notices.isEmpty, "local completion does not cover remote \(state)")
            host.showAgentEvent(.budgetReached(spent: 10, budget: 5))
            suite.expect(host.notices.count == 1, "a spending alert is still delivered during remote \(state)")
        }
        remote.activities = []
        let host = Host()
        host.showAgentEvent(finished)
        suite.expect(host.notices.count == 1, "ordinary local completion is still announced")
    }
}

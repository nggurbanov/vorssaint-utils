// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import SQLite3

/// Names only: never reads transcripts, provider credentials or auth tables.
/// Native IDs join T3's titles to existing usage, without importing usage again.
struct T3LocalMetadata: Equatable {
    struct Session: Equatable {
        let project: AgentProjectIdentity
        let title: String
    }

    var sessions: [String: Session] = [:]

    var projectsBySession: [String: AgentProjectIdentity] { sessions.mapValues(\.project) }

    func session(provider: AgentProvider, nativeID: String) -> Session? {
        sessions[AgentProjectIdentity.sessionKey(provider: provider, session: nativeID)]
    }

    func liveTitle(provider: AgentProvider, nativeID: String) -> String? {
        guard let session = session(provider: provider, nativeID: nativeID) else { return nil }
        return session.title.isEmpty ? session.project.name : session.title
    }

    static func read(home: URL) -> T3LocalMetadata {
        read(database: home.appending(path: ".t3/userdata/statev2.sqlite"))
    }

    static func read(database: URL) -> T3LocalMetadata {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return T3LocalMetadata()
        }
        defer { sqlite3_close(db) }
        // Metadata is optional; a busy or incompatible T3 must not stall log reads.
        sqlite3_busy_timeout(db, 50)
        let sql = """
            SELECT pt.driver,
                   json_extract(pt.payload_json, '$.nativeThreadRef.nativeId'),
                   p.project_id, p.title, t.title
            FROM orchestration_v2_projection_provider_threads pt
            JOIN orchestration_v2_projection_threads t ON t.thread_id = pt.thread_id
            JOIN projection_projects p ON p.project_id = t.project_id
            WHERE t.deleted_at IS NULL AND p.deleted_at IS NULL
              AND json_extract(pt.payload_json, '$.nativeThreadRef.strength') = 'strong'
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return T3LocalMetadata() }
        defer { sqlite3_finalize(statement) }
        var result = T3LocalMetadata()
        var ambiguous: Set<String> = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let provider = AgentProvider(rawValue: text(statement, 0)),
               !text(statement, 1).isEmpty, !text(statement, 2).isEmpty,
               !text(statement, 3).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let key = AgentProjectIdentity.sessionKey(provider: provider, session: text(statement, 1))
                let value = Session(project: AgentProjectIdentity(id: "t3-local:" + text(statement, 2),
                                                                  name: text(statement, 3)),
                                    title: text(statement, 4))
                if let existing = result.sessions[key], existing != value { ambiguous.insert(key) }
                result.sessions[key] = value
            }
            status = sqlite3_step(statement)
        }
        // Never publish a partial join after a busy database or malformed row.
        guard status == SQLITE_DONE else { return T3LocalMetadata() }
        for key in ambiguous { result.sessions[key] = nil }
        return result
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}

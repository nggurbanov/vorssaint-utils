// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Pairing UI adapted from Bruno Hjorth (liltaket), PR #2747.

import SwiftUI

struct T3CodeSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var t3 = T3CodeActivityService.shared
    @State private var t3Endpoint = ""
    @State private var t3PairingCode = ""
    @State private var t3Error: String?
    @State private var pairingTask: Task<Void, Never>?

    private var t3Text: T3CodeStrings { T3CodeStrings(l10n.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t3Text.source)
                    Text(t3Text.statusText(t3.state))
                        .font(.caption)
                        .foregroundStyle(t3.state == .connected ? .green : .secondary)
                }
                Spacer()
            }
            ForEach(t3.connectionStatuses) { connection in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.connection.label).font(.subheadline)
                        let connectionState = connection.error.map(t3Text.errors) ?? t3Text.statusText(connection.state)
                        Text("\(connectionState) · \(connection.connection.endpoint)")
                            .font(.caption).foregroundStyle(connection.state == .connected ? .green : .secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    Spacer(minLength: 4)
                    Button(t3Text.rePair) { t3Endpoint = connection.connection.endpoint; t3PairingCode = "" }
                        .font(.caption)
                    Button(t3Text.removeEnvironment) { t3.disconnect(connectionID: connection.id) }
                        .font(.caption)
                }
                .padding(.vertical, 2)
            }
            Text(t3Text.environmentsHelp)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(t3Text.endpoint, text: $t3Endpoint)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .accessibilityLabel(t3Text.endpoint)
            SecureField(t3Text.pairingCode, text: $t3PairingCode)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(t3Text.pairingCode)
            Button(t3Text.addEnvironment) {
                t3Error = nil
                pairingTask = Task { @MainActor in
                    let endpoint = t3Endpoint
                    let code = t3PairingCode
                    t3PairingCode = ""
                    defer { pairingTask = nil }
                    do {
                        try await t3.connect(endpoint: endpoint, pairingCode: code)
                    } catch is CancellationError {
                        return
                    } catch let error as T3CodeConnectionError {
                        t3Error = t3Text.errors(error)
                    } catch {
                        t3Error = t3Text.errors(.serverUnavailable)
                    }
                }
            }
            .disabled(t3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || t3PairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || pairingTask != nil)
            Text(t3Text.pairHelp)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(t3Text.remoteHelp)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let t3Error {
                Text(t3Error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            t3.syncWithPreferences()
            if t3Endpoint.isEmpty { t3Endpoint = t3.endpoint }
        }
        .onDisappear {
            pairingTask?.cancel()
            pairingTask = nil
            t3PairingCode = ""
        }
    }

}

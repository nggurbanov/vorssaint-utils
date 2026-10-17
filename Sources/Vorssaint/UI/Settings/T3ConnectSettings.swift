// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct T3ConnectSettings: View {
    @ObservedObject private var cloud = T3ConnectService.shared
    @ObservedObject private var activity = T3CodeActivityService.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.openURL) private var openURL

    private var text: T3ConnectStrings { T3ConnectStrings(l10n.language) }
    private var t3: T3CodeStrings { T3CodeStrings(l10n.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("T3 Connect").font(.subheadline.weight(.semibold))
                Spacer()
                if cloud.busy { ProgressView().controlSize(.small) }
            }
            Text(text.help).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let label = cloud.accountLabel { Text(label).font(.caption).textSelection(.enabled) }
            if cloud.state == .authorizing {
                Text(text.waiting).font(.caption)
                if let code = cloud.userCode {
                    Text(code).font(.system(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                }
                if let url = cloud.verificationURL {
                    Text(url.absoluteString).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let url = cloud.verificationURL {
                        Button(text.browser) { openURL(url) }
                        Button(FeatureStrings.screenshot(l10n.language).copyLink) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                    Button(text.cancel) { cloud.cancelAuthorization() }
                }
            } else {
                HStack {
                    if cloud.state == .signedIn {
                        Button(text.refresh) { cloud.refresh() }
                    } else {
                        Button(text.signIn) { cloud.signIn() }
                    }
                    if cloud.accountLabel != nil || cloud.state == .needsSignIn { Button(text.signOut) { cloud.signOut() } }
                }.disabled(cloud.busy)
                if cloud.state == .signedIn && cloud.environments.isEmpty && !cloud.busy {
                    Text(text.empty).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(cloud.environments) { environment in
                    let connection = activity.connectionStatuses.first {
                        $0.connection.environmentID == environment.id && $0.connection.cloudAccountID != nil
                    }
                    HStack {
                        Text(environment.label).lineLimit(1)
                        Spacer(minLength: 8)
                        if let connection {
                            Text(t3.statusText(connection.state)).font(.caption)
                                .foregroundStyle(connection.state == .connected ? .green : .secondary)
                        }
                        if connection?.state != .connected {
                            Button(t3.connect) { cloud.connect(environment) }.font(.caption).disabled(cloud.busy)
                        }
                    }
                }
            }
            if let error = cloud.error {
                Text(text.error(error)).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { cloud.syncWithPreferences() }
    }
}

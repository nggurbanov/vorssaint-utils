// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The same state mark in the expanded page, compact island and timer companion.
struct NotchT3Mark: View {
    let state: T3ThreadState
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Self.tint(for: state))
            .accessibilityLabel(T3CodeStrings(L10n.shared.language).stateText(state))
    }

    private var symbol: String {
        switch state {
        case .working: "circle.hexagongrid.fill"
        case .waitingForInput: "questionmark.circle.fill"
        case .waitingForApproval: "exclamationmark.shield.fill"
        case .waitingForPlan: "doc.text.magnifyingglass"
        case .limited: "hourglass.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .waiting, .idle, .stopped: "pause.circle"
        }
    }

    static func tint(for state: T3ThreadState) -> Color {
        if state == .completed { return .green }
        if state.needsAttention || state == .failed { return .orange }
        return .white.opacity(0.85)
    }
}

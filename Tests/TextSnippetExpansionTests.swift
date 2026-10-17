// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Runs the production expansion routine against recorded key events, a
/// stand-in paste and a stand-in reading of the focused field. No key reaches
/// the system, the clipboard is never touched and Accessibility is never asked.
enum TextSnippetExpansionTests {
    static let syntheticMarker: Int64 = 1
    /// Everything the routine does, in order: "ask" when it reads the focused
    /// field, "⌫" for each backspace, typed text as itself, "key N" for any
    /// other key, and the stand-in paste's own steps.
    static var log: [String] = []
    static var focusedSelection: (range: NSRange, textLength: Int)?

    final class CGEventSource {
        var userData: Int64 = 0
        init?(stateID: CGEventSourceStateID) {}
    }

    final class CGEvent {
        let keyCode: CGKeyCode
        let keyDown: Bool
        var flags: CGEventFlags = []
        var text = ""
        init?(keyboardEventSource: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool) {
            keyCode = virtualKey
            self.keyDown = keyDown
        }
        func keyboardSetUnicodeString(stringLength: Int, unicodeString: [UInt16]) {
            text = String(decoding: unicodeString.prefix(stringLength), as: UTF16.self)
        }
        func post(tap: CGEventTapLocation) {
            guard keyDown else { return }
            if !text.isEmpty {
                log.append(text)
            } else {
                log.append(keyCode == CGKeyCode(kVK_Delete) ? "⌫" : "key \(keyCode)")
            }
        }
    }

    enum NSWorkspace {
        static let shared = Workspace()
        struct Workspace { let frontmostApplication: Application? = Application() }
        struct Application { let processIdentifier: pid_t = 42 }
    }

    enum SelectedTextReader {
        static func focusedTextSelection(processID: pid_t,
                                         timeout: Float) -> (range: NSRange, textLength: Int)? {
            log.append("ask")
            return focusedSelection
        }
    }

    /// Posts at once what the real paste posts after the modifiers come up.
    final class TransientPaste {
        static let shared = TransientPaste()
        func paste(_ text: String,
                   willPostShortcut: (() -> Void)? = nil,
                   didPostShortcut: (() -> Void)? = nil,
                   didFail: (() -> Void)? = nil) -> Bool {
            log.append("modifiers up")
            willPostShortcut?()
            log.append("paste \(text)")
            didPostShortcut?()
            return true
        }
    }

    static func run(_ suite: TestSuite) {
        defer { log = []; focusedSelection = nil }
        let completion = (range: NSRange(location: 6, length: 2), textLength: 8)
        let deletes = { (count: Int) in Array(repeating: "⌫", count: count) }

        log = []
        focusedSelection = completion
        _ = postExpansion(deleteCount: 6, text: "StartEnd", trailingKeyCode: nil, trailingFlags: [])
        suite.expect(log == ["ask"] + deletes(7) + ["StartEnd"],
                     "an inline completion after a typed trigger takes one more backspace (issue #1377)")

        log = []
        focusedSelection = nil
        _ = postExpansion(deleteCount: 6, text: "StartEnd", trailingKeyCode: nil, trailingFlags: [])
        suite.expect(log == ["ask"] + deletes(6) + ["StartEnd"],
                     "a field without a completion gets exactly the trigger's backspaces")

        log = []
        focusedSelection = completion
        _ = postExpansion(deleteCount: 5, text: "test123", trailingKeyCode: CGKeyCode(kVK_Space),
                          trailingFlags: [], trailingText: " ")
        suite.expect(log == ["ask"] + deletes(6) + ["test123", "key \(kVK_Space)"],
                     "a delimiter-completed trigger clears the completion before typing and the delimiter")

        log = []
        focusedSelection = completion
        _ = postExpansion(deleteCount: 5, text: "first\nsecond", trailingKeyCode: CGKeyCode(kVK_Space),
                          trailingFlags: [], trailingText: " ")
        suite.expect(log == ["modifiers up", "ask"] + deletes(6) + ["paste first\nsecond "],
                     "a multi-line snippet asks the field only when its backspaces go out with the paste")

        log = []
        focusedSelection = completion
        _ = postExpansion(deleteCount: 0, text: "StartEnd", trailingKeyCode: nil, trailingFlags: [])
        suite.expect(log == ["StartEnd"],
                     "an insertion with no trigger to clear never asks the field or deletes")
    }
}

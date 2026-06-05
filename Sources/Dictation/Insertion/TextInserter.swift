import AppKit
import CoreGraphics

/// Inserts text into whatever app currently has keyboard focus. Requires
/// Accessibility permission to post synthetic key events. Call on the main
/// thread (it touches NSPasteboard and posts CGEvents).
struct TextInserter {

    func insert(_ text: String, method: InsertionMethod, restoreClipboard: Bool) {
        switch method {
        case .paste: pasteInsert(text, restoreClipboard: restoreClipboard)
        case .type:  typeInsert(text)
        }
    }

    // MARK: Clipboard + ⌘V (default — reliable and fast for long text)

    private func pasteInsert(_ text: String, restoreClipboard: Bool) {
        let pasteboard = NSPasteboard.general
        let previous = restoreClipboard ? pasteboard.string(forType: .string) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postKeyCombo(virtualKey: 0x09, flags: .maskCommand) // ⌘V

        if let previous {
            // Restore after the paste has been read by the target app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    // MARK: Synthetic unicode typing (alternative)

    private func typeInsert(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Some apps drop very long unicode strings, so type in small chunks.
        for chunk in text.chunked(into: 20) {
            let utf16 = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            utf16.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func postKeyCombo(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}

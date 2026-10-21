#if !SWIFTTERM_EMBEDDED
import Foundation
#endif

/// Scroll coordinates that distinguish Mac history viewport from the live screen.
public struct LiveScreenCoordinates: Sendable {
    public let yBase: Int
    public let yDisp: Int
    public let linesCount: Int
    public let cursorX: Int
    public let cursorY: Int
    public let isAlternate: Bool
}

public extension Terminal {
    func liveScreenCoordinates() -> LiveScreenCoordinates {
        terminalLock.withLock {
            LiveScreenCoordinates(
                yBase: buffer.yBase,
                yDisp: buffer.yDisp,
                linesCount: buffer.lines.count,
                cursorX: buffer.x,
                cursorY: buffer.y,
                isAlternate: isCurrentBufferAlternate
            )
        }
    }

    /// Owned copy of the live activity screen. Uses `yBase`, not Mac `yDisp`.
    func makeLiveScreenSnapshot() -> TerminalRenderSnapshot {
        terminalLock.withLock { makeLiveScreenSnapshotLocked() }
    }

    func makeLiveScreenSnapshotLocked() -> TerminalRenderSnapshot {
        let source = buffer
        let style = options.cursorStyle
        let styleBlinks: Bool
        switch style {
        case .blinkBlock, .blinkBar, .blinkUnderline: styleBlinks = true
        case .steadyBlock, .steadyBar, .steadyUnderline: styleBlinks = false
        }
        let cursor = RenderSnapshotCursor(
            x: max(0, min(cols, source.x)),
            y: max(0, min(rows - 1, source.y)),
            hidden: cursorHidden,
            style: style,
            blink: styleBlinks || cursorBlink
        )
        var copiedRows: [RenderSnapshotRow] = []
        copiedRows.reserveCapacity(rows)
        for y in 0..<rows {
            let index = source.yBase + y
            let line = index >= 0 && index < source.lines.count ? source.lines[index] : nil
            var cells: [RenderSnapshotCell] = []
            cells.reserveCapacity(cols)
            for x in 0..<cols {
                guard let line, x < line.count else {
                    cells.append(RenderSnapshotCell(
                        text: "", width: 1, widthState: .narrow,
                        attribute: CharData.defaultAttr, isProtected: false,
                        semanticContent: .none, payloadID: nil))
                    continue
                }
                let cell = line.packedView(at: x)
                cells.append(RenderSnapshotCell(
                    text: cell.code == 0 || cell.width == 0 ? "" : cell.getText(),
                    width: cell.width,
                    widthState: RenderSnapshotWidthState(cell.packed.widthState),
                    attribute: cell.attribute,
                    isProtected: cell.isProtected,
                    semanticContent: cell.semanticContent,
                    payloadID: cell.packed.payloadCode == 0 ? nil : cell.packed.payloadCode))
            }
            let next = index + 1
            copiedRows.append(RenderSnapshotRow(
                y: y,
                isWrapped: line?.isWrapped ?? false,
                wrapsToNext: next >= 0 && next < source.lines.count && source.lines[next].isWrapped,
                renderMode: line?.renderMode ?? .single,
                cells: cells))
        }
        return TerminalRenderSnapshot(
            cols: cols,
            rows: rows,
            isAlternateScreen: isCurrentBufferAlternate,
            dirtyKind: .full,
            dirtyRange: RenderSnapshotRange(startY: 0, endY: rows - 1),
            scrollDirtyRange: nil,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            cursorColor: cursorColor,
            palette: ansiColors,
            reverseVideo: reverseColors,
            synchronizedOutputActive: synchronizedOutputActive,
            cursor: cursor,
            lines: copiedRows)
    }
}

#if os(macOS) || os(iOS) || os(visionOS)
public extension TerminalView {
    func exportLiveScreen() -> TerminalRenderSnapshot {
        terminal.makeLiveScreenSnapshot()
    }

    func encodeRemoteText(_ text: String) -> [UInt8]? {
        terminal.encodeHostText(text)
    }

    func encodeRemotePaste(_ text: String) -> [UInt8]? {
        terminal.encodeHostTextPaste(text)
    }

    func encodeRemoteKey(name: String, code: String, modifiers: UInt32) -> [UInt8]? {
        terminal.encodeHostKey(key: name, code: code, modifiers: modifiers, eventType: 1, text: nil)
    }

    func setUserInputObserver(_ handler: (@Sendable () -> Void)?) {
        terminal.onRegisteredUserInput = handler
    }

    func sendLocalHostText(_ text: String) -> Bool {
        terminal.sendHostText(text)
    }
}
#endif

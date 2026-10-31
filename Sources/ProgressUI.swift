import AppKit
import Combine
import SwiftUI

/// Progress layout like Finder's copy window: an icon on the left, then a title,
/// a progress bar, and two status lines. While importing, every line is one line high so
/// nothing jumps. A finished result wraps in full, so error messages are never cut off.
struct ProgressCard: View {
    @ObservedObject var importer: Importer

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon
                .font(.system(size: 30, weight: .regular))
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(isFinished ? nil : 1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                if importer.phase != .idle { bar }

                Text(line1)
                    .font(.system(size: 11)).monospacedDigit()
                    .lineLimit(isFinished ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                if importer.phase != .idle && !line2.isEmpty {
                    Text(line2)
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(isFinished ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isFinished: Bool {
        if case .finished = importer.phase { return true }
        return false
    }

    @ViewBuilder private var icon: some View {
        switch importer.phase {
        case .finished(let o) where o.kind == .failure:
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            Image(systemName: "sdcard.fill").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var bar: some View {
        switch importer.phase {
        case .preparing:
            ProgressView().progressViewStyle(.linear)
        case .finished(let o) where o.kind == .failure:
            Bar(value: importer.totalFiles > 0 ? Double(importer.doneFiles) / Double(importer.totalFiles) : 0, color: .orange)
        default:
            Bar(value: importer.fraction, color: .accentColor)
        }
    }

    private var title: String {
        switch importer.phase {
        case .idle: return "Waiting for a card"
        case .preparing: return "Preparing to import from \(importer.cardName)"
        case .importing, .ejecting:
            // Total size is on the line below.
            if importer.newFiles == 0 { return "Clearing \(Importer.photos(importer.totalFiles)) from \(importer.cardName)" }
            return "Importing \(Importer.photos(importer.newFiles)) from \(importer.cardName)"
        case .finished(let o): return o.title
        }
    }

    private var line1: String {
        switch importer.phase {
        case .idle: return "Insert a card to import its photos."
        case .preparing: return "Looking for new photos…"
        case .importing, .ejecting:
            return "\(Importer.bytes(importer.estimatedDoneBytes)) of \(Importer.bytes(importer.totalBytes)) · \(importer.doneFiles.formatted()) of \(Importer.photos(importer.totalFiles))"
        case .finished(let o): return o.line1
        }
    }

    private var line2: String {
        switch importer.phase {
        case .idle: return " "
        case .preparing: return ""
        case .importing: return Importer.remainingText(importer.remaining)
        case .ejecting: return "Ejecting card…"
        case .finished(let o): return o.line2
        }
    }
}

/// Same size and shape as the system bar. The system bar turns grey when its window isn't focused,
/// which is the case for a popover that opened by itself, so this one keeps its colour.
struct Bar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(6, g.size.width * min(1, max(0, value))))
                    .animation(.linear(duration: 0.5), value: value)
            }
        }
        .frame(height: 6)
        .padding(.vertical, 5)
    }
}

/// The menu-bar item and its popover. The popover opens on its own when a card goes in, and the
/// progress shows in exactly one place: the popover while it's open, the menu bar while it's closed.
@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    static let shared = StatusController()

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var changes: AnyCancellable?
    private var closeWork: DispatchWorkItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        self.item = item

        let host = NSHostingController(rootView: MenuView(importer: .shared))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.delegate = self

        // objectWillChange fires before the change lands, so read the new state on the next turn.
        changes = Importer.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    /// Clicking the icon toggles the popover.
    @objc private func clicked() {
        if popover.isShown { popover.performClose(nil) } else { show(pinned: false) }
    }

    /// pinned: opened by the app, and stays open while you work elsewhere until you click the icon.
    /// Not pinned: opened by you, and closes when you click away, like any menu.
    private func show(pinned: Bool) {
        closeWork?.cancel()
        popover.behavior = pinned ? .applicationDefined : .transient
        if !pinned { NSApp.activate() } // click-away closing needs the app active; auto-open must not steal focus
        if !popover.isShown, let button = item?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Don't give the first checkbox keyboard focus (and its focus ring) on open.
            DispatchQueue.main.async { self.popover.contentViewController?.view.window?.makeFirstResponder(nil) }
        }
        refresh()
    }

    func importStarted() { show(pinned: true) }

    /// A success closes the popover after 8 s. A failure opens it, and it stays until you click the icon.
    func importFinished(success: Bool) {
        closeWork?.cancel()
        guard success else { show(pinned: true); return }
        guard popover.isShown else { return }
        let work = DispatchWorkItem { [weak self] in self?.popover.performClose(nil) }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.closeWork?.cancel()
            self.refresh()
        }
    }

    private func refresh() {
        guard let button = item?.button else { return }
        let importer = Importer.shared
        let failed: Bool = { if case .finished(let o) = importer.phase { return o.kind == .failure }; return false }()

        let symbol = importer.isBusy ? "sdcard.fill" : failed && !popover.isShown ? "exclamationmark.triangle" : "sdcard"
        if button.image?.name() != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SD Card Photo Sweeper")
            image?.isTemplate = true
            image?.setName(symbol)
            button.image = image
        }

        // Progress in one place only: here when the popover is closed, in the popover when it's open.
        let title = importer.isBusy && !popover.isShown ? " " + Self.menuBarText(importer) : ""
        if button.title != title { button.title = title }
    }

    /// "42% · 2:40"
    private static func menuBarText(_ importer: Importer) -> String {
        switch importer.phase {
        case .preparing: return "Preparing…"
        case .ejecting: return "Ejecting…"
        default:
            let pct = "\(Int(importer.fraction * 100))%"
            return importer.remaining.map { "\(pct) · \(Importer.shortRemaining($0))" } ?? pct
        }
    }
}

import SwiftUI
import UserNotifications

@main
enum Entry {
    static func main() {
        // `SDCardPhotoSweeper --scan /Volumes/CARD` prints what an insert would import, then exits. It writes nothing.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            let volume = URL(fileURLWithPath: args[i + 1])
            let pair = args.contains("--pair")
            let ledger = Ledger()
            let all = Scanner.scan(dcim: volume.appendingPathComponent("DCIM"), pairJPEG: pair)
            let todo = all.filter { !ledger.contains($0.raw.key) }
            for item in todo {
                print(item.raw.url.path + (item.jpeg.map { "  + " + $0.url.lastPathComponent } ?? ""))
            }
            let bytes = todo.reduce(Int64(0)) { $0 + $1.bytes }
            print("card: \(Scanner.isCard(volume)), found \(all.count), new \(todo.count) (\(Importer.bytes(bytes))), ledger \(ledger.count) entries")
            return
        }
        if let i = args.firstIndex(of: "--demo") {
            // `--demo [MB/s] [prior MB/s]`: simulated import of 150 RAWs (~45 MB each).
            let num = { (k: Int) -> Double? in i + k < args.count ? Double(args[i + k]) : nil }
            let items = (1...150).map { n in
                let f = CardFile(url: URL(fileURLWithPath: "/Volumes/DEMO_CARD/DCIM/DSCF\(n).RAF"),
                                 key: FileKey(name: "DSCF\(n).RAF", size: Int64.random(in: 38_000_000...52_000_000), mtime: 0))
                return ImportItem(raw: f, jpeg: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Importer.shared.runDemo(.init(items: items, speed: (num(1) ?? 90) * 1e6, prior: num(2).map { $0 * 1e6 }))
            }
        }
        PhotoSweeperApp.main()
    }
}

struct PhotoSweeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The menu-bar item is AppKit (StatusController), because SwiftUI's MenuBarExtra can't open its popover by itself.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { StatusController.shared.install() }
        if !CommandLine.arguments.contains("--demo") { Task { @MainActor in Importer.shared.start() } }
    }

    // Show banners even while the app is frontmost (e.g. the menu is open).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

struct MenuView: View {
    @ObservedObject var importer: Importer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressCard(importer: importer)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Remove from card after verifying", isOn: $importer.removeFromCard)
                    .disabled(importer.isBusy)
                Toggle("Open at login", isOn: Binding(
                    get: { importer.openAtLogin },
                    set: { importer.setOpenAtLogin($0) }))
                if !importer.settingsError.isEmpty {
                    Text(importer.settingsError).font(.caption).foregroundStyle(.red)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .toggleStyle(.checkbox)
        .padding(12)
        .frame(width: 320)
    }
}

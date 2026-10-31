import AppKit
import Photos
import ServiceManagement
import UserNotifications

/// How an import ended. Shown in the progress window, the menu, and the notification.
struct Outcome: Equatable {
    enum Kind { case success, nothingNew, failure }
    let kind: Kind
    let title: String
    let line1: String
    let line2: String
}

/// Speed estimate (bytes/s) from finished batches. Measures card read plus Photos ingest.
struct Estimator {
    /// Speed saved from an earlier import (this card if known). Counts as 5 s of measurement, so real data soon outweighs it.
    var prior: Double?
    private var samples: [(bytes: Double, seconds: Double)] = []

    init(prior: Double?) { self.prior = prior }

    var hasMeasurement: Bool { !samples.isEmpty }

    mutating func add(bytes: Int64, seconds: Double) {
        if seconds > 0 { samples.append((Double(bytes), seconds)) }
    }

    var rate: Double? {
        // The first batch includes Photos warming up. Drop it once there is anything else to go on.
        let used = samples.count >= 2 ? samples.dropFirst() : samples[...]
        let b = used.reduce(0) { $0 + $1.bytes }
        let s = used.reduce(0) { $0 + $1.seconds }
        let priorWeight = 5.0
        switch (s > 0, prior) {
        case (true, let p?): return (b + p * priorWeight) / (s + priorWeight)
        case (true, nil): return b / s
        case (false, let p?): return p
        case (false, nil): return nil
        }
    }

    /// Speed to show an estimate from. With no saved speed, the warm-up batch alone is too slow to trust
    /// (it overestimated by 55% in the demo), so this waits for a second batch, a few seconds later.
    var displayRate: Double? {
        prior == nil && samples.count < 2 ? nil : rate
    }

    /// Speed over the whole import, for the summary.
    var overall: Double? {
        let b = samples.reduce(0) { $0 + $1.bytes }
        let s = samples.reduce(0) { $0 + $1.seconds }
        return s > 0 ? b / s : nil
    }
}

/// Watches for cards, imports them into Photos one at a time, and publishes progress.
@MainActor
final class Importer: ObservableObject {
    static let shared = Importer()

    enum Phase: Equatable { case idle, preparing, importing, ejecting, finished(Outcome) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var cardName = ""
    @Published private(set) var doneFiles = 0
    @Published private(set) var totalFiles = 0
    /// Photos not yet in Photos. The rest of totalFiles are already imported and only being cleared from the card.
    @Published private(set) var newFiles = 0
    @Published private(set) var doneBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    /// Smoothed seconds left. nil until there is a speed to go on.
    @Published private(set) var remaining: Double?
    @Published private(set) var now = Date()

    /// Delete each photo from the card once its copy in Photos is verified byte for byte.
    @Published var removeFromCard: Bool {
        didSet { UserDefaults.standard.set(removeFromCard, forKey: "removeFromCard") }
    }
    @Published private(set) var openAtLogin = false
    @Published private(set) var settingsError = ""

    let ledger = Ledger()

    private let maxBatch = 50
    private let firstBatch = 2        // small, so a real measurement arrives within seconds
    private let secondsPerBatch = 3.0 // later batches are sized to about this much work

    private var queue: [URL] = []
    private var current: URL?
    private var ticker: Timer?
    private var estimator = Estimator(prior: nil)
    private var batchStart: Date?
    private var batchBytes: Int64 = 0
    private var lastTick = Date()

    var isBusy: Bool {
        switch phase { case .preparing, .importing, .ejecting: return true; default: return false }
    }

    private init() {
        Self.migrateSettingsFromOldName()
        UserDefaults.standard.register(defaults: ["removeFromCard": true])
        removeFromCard = UserDefaults.standard.bool(forKey: "removeFromCard")
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if !UserDefaults.standard.bool(forKey: "loginDefaultApplied") {
            UserDefaults.standard.set(true, forKey: "loginDefaultApplied")
            try? SMAppService.mainApp.register()
        }
        openAtLogin = SMAppService.mainApp.status == .enabled

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in Importer.shared.enqueue(url) }
        }
        // Cards already mounted at launch (login, or after a crash) are picked up too.
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        mounted.forEach(enqueue)
    }

    func setOpenAtLogin(_ on: Bool) {
        settingsError = ""
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            settingsError = "Open at login: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Queue

    private func enqueue(_ volume: URL) {
        let v = volume.standardizedFileURL
        guard Scanner.isCard(v), v != current, !queue.contains(v) else { return }
        queue.append(v)
        if current == nil { Task { await runQueue() } }
    }

    private func runQueue() async {
        while !queue.isEmpty {
            let v = queue.removeFirst()
            current = v
            await importCard(v)
            current = nil
        }
    }

    // MARK: Import

    private func importCard(_ volume: URL) async {
        cardName = volume.lastPathComponent
        doneFiles = 0; totalFiles = 0; newFiles = 0; doneBytes = 0; totalBytes = 0
        remaining = nil
        batchStart = nil
        let speedKey = demo == nil ? Self.speedKey(for: volume) : nil
        estimator = Estimator(prior: demo == nil ? Self.savedSpeed(speedKey) : demo?.prior)
        predictions = []
        phase = .preparing
        StatusController.shared.importStarted()
        startTicker()
        defer { stopTicker() }

        let canAdd = demo != nil ? true : [.authorized, .limited].contains(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
        guard canAdd else {
            finish(Outcome(kind: .failure, title: "SD Card Photo Sweeper can't add to Photos",
                           line1: "Allow it in System Settings › Privacy & Security › Photos.",
                           line2: "Then reinsert the card."))
            return
        }

        // Removing from the card needs: the setting on, a writable card, and full Photos access to read the copies back.
        let readOnly = (try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        var canRead = false
        if removeFromCard && !readOnly && demo == nil {
            canRead = await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
        }
        let removing = removeFromCard && !readOnly && canRead
        let keptReason: String? = !removeFromCard || demo != nil ? nil
            : readOnly ? "The card is locked, so nothing was removed from it."
            : !canRead ? "Nothing was removed from the card: allow SD Card Photo Sweeper full access in Settings › Privacy & Security › Photos."
            : nil

        let dcim = volume.appendingPathComponent("DCIM")
        let all: [ImportItem]
        if let d = demo { all = d.items } else { all = await Task.detached { Scanner.scan(dcim: dcim, pairJPEG: false) }.value }

        // New photos get imported. Already-imported ones still on the card get checked and removed.
        let work: [(item: ImportItem, isNew: Bool)] = all.compactMap { item in
            if demo != nil || !ledger.contains(item.raw.key) { return (item, true) }
            return removing ? (item, false) : nil
        }
        let newCount = work.filter(\.isNew).count

        if work.isEmpty {
            phase = .ejecting
            let ejected = await eject(volume)
            finish(Outcome(kind: .nothingNew, title: "No new photos on \(cardName)",
                           line1: "All \(Self.photos(all.count)) on this card are already in Photos.",
                           line2: [keptReason, ejected ? "Card ejected. You can remove it." : "Couldn't eject. Eject it in Finder."]
                               .compactMap { $0 }.joined(separator: " ")))
            return
        }

        totalFiles = work.count
        newFiles = newCount
        totalBytes = work.reduce(0) { $0 + $1.item.bytes }
        let avgItemBytes = Double(totalBytes) / Double(totalFiles)
        phase = .importing
        updateRemaining(smooth: false)
        let started = Date()
        importStart = started

        var imported = 0, failed = 0, removed = 0, kept = 0
        var outOfSpace = false
        var importedBytes: Int64 = 0
        var lastError: String?
        var index = 0
        while index < work.count {
            let size: Int
            if !estimator.hasMeasurement { size = firstBatch }
            else if let r = estimator.overall { size = Int(r * secondsPerBatch / avgItemBytes) }
            else { size = maxBatch }
            let batch = Array(work[index..<min(index + max(1, min(maxBatch, size)), work.count)])
            let thisBatchBytes = batch.reduce(0) { $0 + $1.item.bytes }
            let fresh = batch.filter(\.isNew).map(\.item)
            let old = batch.filter { !$0.isNew }.map(\.item)

            // Stop if the card is gone: every remaining batch would fail.
            guard demo != nil || FileManager.default.fileExists(atPath: dcim.path) else {
                failed += work[index...].filter(\.isNew).count
                lastError = "The card was removed."
                break
            }

            // Stop before Photos runs out of room, rather than letting every remaining batch fail.
            let freshBytes = fresh.reduce(0) { $0 + $1.bytes }
            if demo == nil, !fresh.isEmpty, let free = Self.freeSpace(), free < freshBytes + Self.spaceReserve {
                outOfSpace = true
                failed += work[index...].filter(\.isNew).count
                break
            }

            batchStart = Date()
            batchBytes = thisBatchBytes
            var checks: [(files: [CardFile], assetId: String, hashes: [URL: String])] = []

            if !fresh.isEmpty {
                // Hash first: this reads the batch off the card, so Photos' read that follows will likely come from memory.
                let hashes = removing ? await Self.hashFiles(fresh.flatMap(\.files)) : [:]
                var done: [(item: ImportItem, id: String)] = []
                do {
                    let ids = try await (demo != nil ? simulateBatch(fresh) : addToPhotos(fresh))
                    done = Array(zip(fresh, ids))
                } catch {
                    lastError = Self.describe(error)
                    if Self.isOutOfSpace(error) {
                        outOfSpace = true
                    } else if fresh.count > 1 {
                        // One bad file fails its whole batch. Retry one at a time, so only that file fails.
                        for item in fresh {
                            do { done.append((item, try await addToPhotos([item])[0])) }
                            catch {
                                lastError = Self.describe(error)
                                if Self.isOutOfSpace(error) { outOfSpace = true; break }
                            }
                        }
                    }
                    failed += fresh.count - done.count
                }

                if !done.isEmpty {
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    let entries = done.flatMap { item, id in
                        item.files.map { LedgerEntry(name: $0.key.name, size: $0.key.size, mtime: $0.key.mtime,
                                                     assetId: id, importedAt: stamp, sha256: hashes[$0.url]) }
                    }
                    var recorded = demo != nil
                    if demo == nil {
                        do { try ledger.append(entries); recorded = true }
                        catch { lastError = "Couldn't save the import record: \(error.localizedDescription)" }
                    }
                    imported += done.count
                    importedBytes += done.reduce(0) { $0 + $1.item.bytes }
                    // Only photos the ledger has recorded may leave the card.
                    if removing && recorded {
                        checks += done.map { ($0.item.files, $0.id, hashes) }
                    }
                }
            }

            if !old.isEmpty {
                let hashes = await Self.hashFiles(old.flatMap(\.files))
                for item in old {
                    // A pair's JPEG only goes if it was imported too; otherwise it stays on the card.
                    let files = item.files.filter { ledger.assetId(for: $0.key) != nil }
                    if let id = ledger.assetId(for: item.raw.key) { checks.append((files, id, hashes)) }
                }
            }

            for check in checks {
                if await Self.verifyAndRemove(check.files, assetId: check.assetId, cardHashes: check.hashes) {
                    removed += 1
                } else {
                    kept += 1
                }
            }

            estimator.add(bytes: thisBatchBytes, seconds: Date().timeIntervalSince(batchStart!))
            index += batch.count
            batchStart = nil
            doneFiles += batch.count
            doneBytes += thisBatchBytes
            updateRemaining(smooth: true)
            if outOfSpace {
                failed += work[index...].filter(\.isNew).count
                break
            }
        }

        let took = Date().timeIntervalSince(started)
        if demo != nil { reportPredictions(took: took) }
        if demo == nil, let r = estimator.overall { Self.saveSpeed(r, speedKey) }
        let speed = estimator.overall.map { " · \(Self.mbps($0))" } ?? ""

        // What happened on the card, in one sentence.
        var cardNote: String?
        if let keptReason { cardNote = keptReason }
        else if removing {
            cardNote = kept == 0
                ? "Checked each copy in Photos, then removed \(Self.photos(removed)) from the card."
                : "Removed \(Self.photos(removed)) from the card. Kept \(kept): the copy in Photos couldn't be confirmed."
        }

        // Eject even after a failure, so the card is safe to pull (deletions are written on unmount).
        // Reinserting it retries whatever is left.
        let cardGone = demo == nil && !FileManager.default.fileExists(atPath: dcim.path)
        phase = .ejecting
        let ejected = cardGone ? false : await eject(volume)
        let ejectNote = cardGone ? nil
            : ejected ? (failed == 0 ? "Card ejected. You can remove it." : "Card ejected.")
            : removed > 0 ? "Couldn't eject. Eject it in Finder before removing it, so the deletions are saved."
            : "Couldn't eject. Eject it in Finder."

        if failed == 0 {
            finish(Outcome(kind: .success,
                           title: imported > 0 ? "Imported \(Self.photos(imported)) from \(cardName)"
                                               : "Cleared \(Self.photos(removed)) from \(cardName)",
                           line1: imported > 0 ? "\(Self.bytes(importedBytes)) in \(Self.duration(took))\(speed)"
                                               : "They were already in Photos.",
                           line2: [cardNote, ejectNote].compactMap { $0 }.joined(separator: " ")))
        } else if outOfSpace {
            let leftBytes = work.filter(\.isNew).reduce(Int64(0)) { $0 + $1.item.bytes } - importedBytes
            let need = max(0, leftBytes + Self.spaceReserve - (Self.freeSpace() ?? 0))
            finish(Outcome(kind: .failure,
                           title: "Your Mac is out of storage space",
                           line1: "Imported \(imported) of \(Self.photos(newCount)). Free up about \(Self.bytes(need)), then reinsert the card to import the other \(failed).",
                           line2: [cardNote, ejectNote].compactMap { $0 }.joined(separator: " ")))
        } else {
            finish(Outcome(kind: .failure,
                           title: "Imported \(imported) of \(Self.photos(newCount)), \(failed) failed",
                           line1: lastError ?? "Unknown error.",
                           line2: [cardNote, ejectNote, "Reinsert the card to retry the \(failed) that failed."]
                               .compactMap { $0 }.joined(separator: " ")))
        }
    }

    /// Room kept free on the Mac after an import, so the system doesn't run out.
    static let spaceReserve: Int64 = 2_000_000_000

    /// Free space on the volume holding the Photos library (assumed to be the home volume, where
    /// ~/Pictures is), counting space macOS can reclaim on demand.
    static func freeSpace() -> Int64? {
        let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return (try? pictures.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == PHPhotosErrorDomain && e.code == PHPhotosError.notEnoughSpace.rawValue)
            || (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError)
            || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC))
    }

    /// A Photos error in plain words. Falls back to the system description.
    static func describe(_ error: Error) -> String {
        if isOutOfSpace(error) { return "Your Mac is out of storage space." }
        let e = error as NSError
        guard e.domain == PHPhotosErrorDomain, let code = PHPhotosError.Code(rawValue: e.code) else {
            return e.localizedDescription
        }
        switch code {
        case .invalidResource: return "Photos couldn't read a file. It may be damaged, or from a camera Photos doesn't support yet."
        case .missingResource: return "A file disappeared from the card during the import."
        case .operationInterrupted: return "Photos was interrupted. Reinsert the card to try again."
        case .libraryVolumeOffline: return "The drive holding your Photos library isn't connected."
        case .switchingSystemPhotoLibrary, .relinquishingLibraryBundleToWriter: return "The Photos library was moved or switched during the import."
        case .accessRestricted, .accessUserDenied: return "SD Card Photo Sweeper isn't allowed to add to Photos. Check System Settings › Privacy & Security › Photos."
        default: return "Photos error \(e.code): \(e.localizedDescription)"
        }
    }

    /// Hashes card files off the main thread. Files that can't be read are left out, so they won't be removed.
    private static func hashFiles(_ files: [CardFile]) async -> [URL: String] {
        await Task.detached {
            var out: [URL: String] = [:]
            for f in files { out[f.url] = try? Verifier.sha256(of: f.url) }
            return out
        }.value
    }

    /// Deletes a photo's card files only if every one has a byte-identical original in the Photos asset.
    /// Returns true if they were removed.
    private static func verifyAndRemove(_ files: [CardFile], assetId: String, cardHashes: [URL: String]) async -> Bool {
        guard !files.isEmpty, !assetId.isEmpty else { return false }
        for f in files {
            guard let cardHash = cardHashes[f.url],
                  let libraryHash = await Verifier.libraryHash(assetId: assetId, filename: f.key.name),
                  cardHash == libraryHash
            else { return false }
        }
        // All verified. Delete permanently (no Trash on the card).
        var allGone = true
        for f in files {
            if (try? FileManager.default.removeItem(at: f.url)) == nil { allGone = false }
        }
        return allGone
    }

    /// One `performChanges` call per batch. The batch succeeds or fails as a whole.
    private func addToPhotos(_ batch: [ImportItem]) async throws -> [String] {
        final class IDs: @unchecked Sendable { var list: [String] = [] }
        let ids = IDs()
        try await PHPhotoLibrary.shared().performChanges {
            for item in batch {
                let request = PHAssetCreationRequest.forAsset()
                if let jpeg = item.jpeg {
                    request.addResource(with: .photo, fileURL: jpeg.url, options: Self.options(jpeg))
                    request.addResource(with: .alternatePhoto, fileURL: item.raw.url, options: Self.options(item.raw))
                } else {
                    request.addResource(with: .photo, fileURL: item.raw.url, options: Self.options(item.raw))
                }
                ids.list.append(request.placeholderForCreatedAsset?.localIdentifier ?? "")
            }
        }
        return ids.list
    }

    nonisolated private static func options(_ file: CardFile) -> PHAssetResourceCreationOptions {
        let o = PHAssetResourceCreationOptions()
        o.shouldMoveFile = false // Photos copies. Removal from the card happens only after verification.
        o.originalFilename = file.key.name
        return o
    }

    /// Unmounts and ejects the card. Retries a few times in case something still holds a file open.
    private func eject(_ volume: URL) async -> Bool {
        if demo != nil { try? await Task.sleep(for: .seconds(1)); return true }
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            let ok = await Task.detached {
                (try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)) != nil
            }.value
            if ok { return true }
        }
        return false
    }

    private func finish(_ outcome: Outcome) {
        phase = .finished(outcome)
        remaining = nil
        StatusController.shared.importFinished(success: outcome.kind != .failure)
        let content = UNMutableNotificationContent()
        content.title = outcome.title
        content.body = outcome.line1 + "\n" + outcome.line2
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Progress

    private func startTicker() {
        lastTick = Date()
        now = lastTick
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in Importer.shared.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        now = Date()
        if phase == .importing {
            updateRemaining(smooth: true)
            if demo != nil, let r = remaining, let s = importStart {
                predictions.append((now.timeIntervalSince(s), now.timeIntervalSince(s) + r))
            }
        }
    }

    /// Bytes done, plus an estimate for the batch in flight (capped below its total, so the bar never runs ahead).
    var estimatedDoneBytes: Int64 {
        guard let start = batchStart, let r = estimator.displayRate else { return doneBytes }
        let inFlight = min(Double(batchBytes) * 0.95, r * now.timeIntervalSince(start))
        return doneBytes + Int64(inFlight)
    }

    var fraction: Double {
        switch phase {
        case .ejecting, .finished: return 1
        default: return totalBytes > 0 ? min(1, Double(estimatedDoneBytes) / Double(totalBytes)) : 0
        }
    }

    /// Time left = bytes left ÷ measured speed. The displayed value counts down in real time and
    /// eases toward each new raw estimate, so it moves steadily instead of jumping every batch.
    private func updateRemaining(smooth: Bool) {
        let t = Date()
        defer { lastTick = t }
        guard let r = estimator.displayRate, r > 0 else { remaining = nil; return }
        let raw = Double(totalBytes - estimatedDoneBytes) / r
        guard smooth, let shown = remaining else { remaining = raw; return }
        let counted = max(0, shown - t.timeIntervalSince(lastTick))
        // Lean on the raw estimate once real measurements exist; before that, it is only the saved speed.
        let weight = estimator.hasMeasurement ? 0.25 : 0.05
        remaining = counted + (raw - counted) * weight
    }

    // MARK: Demo (`--demo`): real UI and timing logic, simulated card. Touches neither Photos nor the ledger.

    struct Demo {
        var items: [ImportItem]
        var speed: Double          // simulated bytes/s
        var prior: Double?         // saved speed the estimate starts from
        var warmup: Double = 1.5   // Photos' slower first batch, in seconds
    }
    var demo: Demo?
    private var importStart: Date?
    private var predictions: [(at: Double, total: Double)] = []

    func runDemo(_ d: Demo) {
        demo = d
        Task { await importCard(URL(fileURLWithPath: "/Volumes/DEMO_CARD")) }
    }

    private func simulateBatch(_ batch: [ImportItem]) async throws -> [String] {
        guard let d = demo else { return [] }
        let bytes = Double(batch.reduce(0) { $0 + $1.bytes })
        let noise = Double.random(in: 0.85...1.15)
        let seconds = bytes / d.speed * noise + (estimator.hasMeasurement ? 0.1 : d.warmup)
        try await Task.sleep(for: .seconds(seconds))
        return batch.map { _ in "demo" }
    }

    private func reportPredictions(took: Double) {
        var out = String(format: "demo: actual %.1f s\n", took)
        for pct in [0.05, 0.10, 0.25, 0.50, 0.75, 0.90] {
            if let p = predictions.first(where: { $0.at >= took * pct }) {
                out += String(format: "  at %3.0f%% of time: predicted total %.1f s (error %+.0f%%)\n",
                              pct * 100, p.total, (p.total - took) / took * 100)
            }
        }
        FileHandle.standardError.write(Data(out.utf8))
    }

    /// The app used to be called "SD Import" (dev.dion.SDImport). Carry over its settings and saved card speeds once.
    private static func migrateSettingsFromOldName() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromSDImport"), let old = UserDefaults(suiteName: "dev.dion.SDImport") else { return }
        for (key, value) in old.dictionaryRepresentation() where key.hasPrefix("speed.") || key == "removeFromCard" {
            d.set(value, forKey: key)
        }
        d.set(true, forKey: "migratedFromSDImport")
    }

    // MARK: Saved speeds

    /// Card speed is the main variable, so the speed is saved per card (volume UUID), with the last import as fallback.
    private static func speedKey(for volume: URL) -> String? {
        (try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString.map { "speed.\($0)" }
    }

    private static func savedSpeed(_ key: String?) -> Double? {
        let d = UserDefaults.standard
        if let key, d.double(forKey: key) > 0 { return d.double(forKey: key) }
        let last = d.double(forKey: "speed.last")
        return last > 0 ? last : nil
    }

    private static func saveSpeed(_ bps: Double, _ key: String?) {
        UserDefaults.standard.set(bps, forKey: "speed.last")
        if let key { UserDefaults.standard.set(bps, forKey: key) }
    }

    // MARK: Formatting

    static func photos(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "photo" : "photos")" }

    static func mbps(_ bytesPerSecond: Double) -> String {
        "\(Int((bytesPerSecond / 1_000_000).rounded())) MB/s"
    }

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return f.string(fromByteCount: n)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t) s" }
        if t < 3600 { return "\(t / 60) min \(t % 60) s" }
        return "\(t / 3600) h \(t % 3600 / 60) min"
    }

    /// "About 2 min 40 s remaining". Rounded more coarsely as the time gets longer.
    static func remainingText(_ s: Double?) -> String {
        guard let s else { return "Estimating time remaining…" }
        switch s {
        case ..<10: return "A few seconds remaining"
        case ..<60: return "About \(Int((s / 5).rounded()) * 5) seconds remaining"
        case ..<600:
            let r = Int((s / 10).rounded()) * 10
            return r % 60 == 0 ? "About \(r / 60) min remaining" : "About \(r / 60) min \(r % 60) s remaining"
        case ..<3600: return "About \(Int((s / 60).rounded())) min remaining"
        default:
            let m = Int((s / 60).rounded())
            return "About \(m / 60) h \(m % 60) min remaining"
        }
    }

    /// Compact form for the menu bar: "2:40", "1:05:00".
    static func shortRemaining(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

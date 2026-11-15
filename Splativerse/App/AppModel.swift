import SwiftUI
import SplativerseCore

@MainActor @Observable
final class AppModel {
    let library: ScanLibrary
    var scans: [ScanRecord] = []
    var selectedID: UUID?
    var busy = false
    var message = "Preparing your library…"
    var issue: String?
    var lastLoadFailure: String?
    var connectedDownloads = false
    var prepared = false
    var isImmersive = false
    var opening = false
    var menuHidden = false
    var closingImmersive = false
    var renderStatus = RenderStatus()
    var activeRequest: RenderRequest?
    var firstRun = !UserDefaults.standard.bool(forKey: "Splativerse.setupComplete")

    init(library: ScanLibrary? = nil) {
        if let library { self.library = library; return }
        let fm = FileManager.default
        self.library = ScanLibrary(
            documentsDirectory: fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
            supportDirectory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Splativerse", isDirectory: true))
    }
    var selected: ScanRecord? { scans.first { $0.id == selectedID } }

    func bootstrap() async {
        guard !prepared, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            scans = try await library.prepare()
            selectedID = scans.first?.id
            connectedDownloads = await library.hasDownloadsFolder()
            prepared = true
            message = "Library: On My Apple Vision Pro → Splativerse → Scans"
            if connectedDownloads {
                message = "Checking Downloads…"
                let report = try await library.rescanDownloads()
                await finish(report)
            }
        } catch { issue = error.localizedDescription; message = "Library needs attention. Choose Downloads again if access has expired." }
    }

    func chooseDownloads(_ url: URL) async {
        guard !busy else { return }
        busy = true; message = "Copying scans from Downloads…"
        defer { busy = false }
        do {
            let report = try await library.connectDownloads(url)
            connectedDownloads = true
            completeSetup()
            await finish(report)
        } catch { issue = error.localizedDescription }
    }
    func completeSetup() {
        firstRun = false
        UserDefaults.standard.set(true, forKey: "Splativerse.setupComplete")
    }
    func rescan() async {
        guard !busy else { return }
        busy = true; message = "Checking Downloads…"
        defer { busy = false }
        do { await finish(try await library.rescanDownloads()) }
        catch { issue = error.localizedDescription }
    }
    func importScans(_ urls: [URL]) async {
        guard !busy, prepared else { return }
        guard !isImmersive && !opening else { issue = "Leave the current space before importing another scan."; return }
        busy = true; message = "Copying scans into your library…"
        defer { busy = false }
        await finish(await library.importFiles(urls))
    }
    private func finish(_ report: ImportReport) async {
        do { scans = try await library.refresh() }
        catch { issue = error.localizedDescription }
        if selectedID == nil || !scans.contains(where: { $0.id == selectedID }) { selectedID = scans.first?.id }
        if let id = activeRequest?.id { updateScanNavigation(id) }
        message = report.summary
        if !report.failures.isEmpty { issue = report.failures.joined(separator: "\n") }
    }
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            scans = try await library.refresh(); message = "Library refreshed."
            if let id = activeRequest?.id { updateScanNavigation(id) }
        }
        catch { issue = error.localizedDescription }
    }
    func saveSettings(id: UUID, settings: ScanSettings) {
        // Update the selected record immediately so Enter uses the visible settings.
        if let index = scans.firstIndex(where: { $0.id == id }) { scans[index].settings = settings }
        Task {
            do { try await library.updateSettings(id: id, settings: settings) }
            catch { issue = error.localizedDescription }
        }
    }
    func setBubbleRadius(_ radius: Float) {
        guard let scan = selected else { return }
        var settings = scan.settings
        settings.bubbleRadius = BubbleConfiguration(radius: radius).radius
        saveSettings(id: scan.id, settings: settings)
        if isImmersive { RenderControl.shared.enqueue(.setBubbleRadius(settings.bubbleRadius)) }
    }
    func updateScanNavigation(_ sessionID: UUID) {
        let index = (activeRequest?.scanID ?? selectedID).flatMap { id in scans.firstIndex { $0.id == id } }
        let previous = index.map { $0 > 0 } ?? false
        let next = index.map { $0+1 < scans.count } ?? false
        RenderControl.shared.report(sessionID) { $0.canGoPrevious = previous; $0.canGoNext = next }
    }
    func switchScan(by step: Int, sessionID: UUID) async {
        guard abs(step) == 1, let currentID = activeRequest?.scanID,
              let index = scans.firstIndex(where: { $0.id == currentID }), scans.indices.contains(index+step) else {
            RenderControl.shared.report(sessionID) { $0.scanSwitchPending = false }; return
        }
        let scan = scans[index+step]
        let url = await library.fileURL(for: scan)
        guard !RenderControl.shared.shouldStop(sessionID) else { return }
        let request = RenderRequest(id: sessionID,scanID: scan.id,fileURL: url,title: scan.title,settings: scan.settings)
        guard RenderControl.shared.enqueueScan(request) else { return }
        selectedID = scan.id; lastLoadFailure = nil
        activeRequest = request
        updateScanNavigation(sessionID)
    }
    func request(for scan: ScanRecord) async -> RenderRequest {
        RenderRequest(id: UUID(), scanID: scan.id, fileURL: await library.fileURL(for: scan), title: scan.title, settings: scan.settings)
    }
}

import CompositorServices
import SwiftUI
import os

@main
struct SplativerseApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("Splativerse", id: "library") {
            LibraryView(model: model)
        }
        .defaultSize(width: 1000, height: 760)
        ImmersiveSpace(for: RenderRequest.self) { request in
            ScanImmersiveContent(request: request.wrappedValue,model: model)
        }
        .upperLimbVisibility(.visible)
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

/// Own scene monitoring in the immersive space, so hiding the window does not
/// disable Menu/Exit or lose load-error and system-dismissal handling.
private struct ScanImmersiveContent: CompositorContent {
    let request: RenderRequest?
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private static let log = Logger(subsystem: "com.splativerse.vision",category: "PanelMenu")
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var phase
    @State private var monitor: Task<Void,Never>?
    var body: some CompositorContent {
        CompositorLayer(configuration: ScanLayerConfiguration()) { layer in
            if let request { VisionScanRenderer.start(layer,request: request) }
        }
        .onAppear {
            guard let request, monitor == nil else { return }
            RenderControl.shared.setInteractionActive(phase == .active,for: request.id)
            monitor = Task { @MainActor in
                var seenMenu: UInt64 = 0
                var seenScanStep: UInt64 = 0
                var seenLoadFailure: String?
                while !Task.isCancelled {
                    let status = RenderControl.shared.snapshot()
                    guard status.sessionID == request.id else { return }
                    model.renderStatus = status
                    if let detail = status.loadFailure, detail != seenLoadFailure {
                        model.lastLoadFailure = detail
                        if model.menuHidden { openWindow(id: "library"); model.menuHidden = false }
                    }
                    seenLoadFailure = status.loadFailure
                    if status.scanStepSequence != seenScanStep {
                        seenScanStep = status.scanStepSequence
                        await model.switchScan(by: status.scanStep,sessionID: request.id)
                    }
                    if status.menuSequence != seenMenu {
                        seenMenu = status.menuSequence
                        let show = model.menuHidden
                        model.menuHidden = !show
                        if show { openWindow(id: "library") }
                        else { dismissWindow(id: "library") }
                        Self.log.info("Panel Menu toggled settings window: visible=\(show,privacy: .public)")
                    }
                    if status.exitRequested || status.failure != nil || status.closed {
                        guard !model.closingImmersive else { return }
                        model.closingImmersive = true
                        if model.menuHidden { openWindow(id: "library"); model.menuHidden = false }
                        if let error = status.failure {
                            model.issue = error; model.lastLoadFailure = error
                        } else if status.closed && !status.exitRequested && !status.ready {
                            model.lastLoadFailure = "The immersive view closed before completing this session. Last stage: " + status.message
                        }
                        RenderControl.shared.stop(request.id)
                        await dismissImmersiveSpace()
                        if model.activeRequest?.id == request.id { model.isImmersive = false; model.activeRequest = nil; model.closingImmersive = false }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        .onChange(of: phase) { _, value in
            if let request { RenderControl.shared.setInteractionActive(value == .active,for: request.id) }
        }
        .onDisappear {
            monitor?.cancel(); monitor = nil
            guard let request, model.activeRequest?.id == request.id else { return }
            RenderControl.shared.stop(request.id)
            if !model.closingImmersive && !model.renderStatus.ready && model.lastLoadFailure == nil {
                model.lastLoadFailure = "The immersive space was dismissed. Last stage: " + model.renderStatus.message
            }
            model.isImmersive = false; model.activeRequest = nil; model.closingImmersive = false
            if model.menuHidden { openWindow(id: "library"); model.menuHidden = false }
        }
    }
}

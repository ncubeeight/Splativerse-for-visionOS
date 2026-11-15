import SwiftUI
import UniformTypeIdentifiers
import SplativerseCore

extension UTType {
    static let splativersePLY = UTType(filenameExtension: "ply", conformingTo: .data) ?? UTType(importedAs: "com.splativerse.scan.ply", conformingTo: .data)
    static let splativerseSPZ = UTType(filenameExtension: "spz", conformingTo: .data) ?? UTType(importedAs: "com.splativerse.scan.spz", conformingTo: .data)
    static let splativerseSplat = UTType(filenameExtension: "splat", conformingTo: .data) ?? UTType(importedAs: "com.splativerse.scan.splat", conformingTo: .data)
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var pickingFiles = false
    @State private var pickingFolder = false
    @State private var showingFolderInstructions = false
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(model.scans) { scan in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(scan.title).font(.headline).lineLimit(2)
                        Text("\(scan.filename.pathExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: scan.byteCount, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8).tag(scan.id)
                }
            }
            .disabled(model.isImmersive || model.opening)
            .navigationTitle("Splativerse")
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("Import scans…", systemImage: "square.and.arrow.down") { pickingFiles = true }
                        Button("Choose Downloads folder…", systemImage: "folder") { showingFolderInstructions = true }
                        Button("Scan Downloads again", systemImage: "arrow.clockwise") { Task { await model.rescan() } }
                            .disabled(!model.connectedDownloads)
                        Button("Refresh library", systemImage: "arrow.triangle.2.circlepath") { Task { await model.refresh() } }
                    } label: { Label("Files", systemImage: "folder") }
                    .disabled(model.busy || !model.prepared || model.isImmersive || model.opening)
                }
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.isImmersive {
                        Button {
                            model.menuHidden = true
                            dismissWindow(id: "library")
                        } label: {
                            Label("Hide Menu",systemImage: "rectangle.slash").font(.title2.bold()).frame(maxWidth: .infinity).padding(.vertical,12)
                        }.buttonStyle(.borderedProminent).controlSize(.extraLarge)
                        .disabled((!model.renderStatus.ready && model.renderStatus.loadFailure == nil) || !model.renderStatus.flightAvailable || !model.renderStatus.flightEnabled)
                        Text("Look at a gold button and pinch to select: Menu toggles settings, Exit leaves, and Previous/Next browse scans in filename order.").font(.caption)
                    }
                    if let failure = model.lastLoadFailure {
                        VStack(alignment: .leading,spacing: 8) {
                            Label("Scan loading issue",systemImage: "exclamationmark.triangle").font(.headline)
                            Text(failure).textSelection(.enabled)
                            Button("Dismiss message") { model.lastLoadFailure = nil }
                        }.padding().background(.thinMaterial,in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.firstRun && model.prepared { welcome }
                    if let scan = model.selected {
                        ScanDetail(scan: scan, locked: model.isImmersive || model.opening,
                            save: { settings in model.saveSettings(id: scan.id, settings: settings) })
                        .id(scan.id)
                        if model.isImmersive {
                            navigationControls
                            Button("Leave space", systemImage: "door.left.hand.open") { Task { await leave() } }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button { enter(scan) } label: { Label("Enter this space", systemImage: "figure.walk") }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(model.busy || model.opening)
                        }
                    } else if !model.firstRun {
                        ContentUnavailableView("Your spatial library", systemImage: "viewfinder",
                            description: Text("Import a PLY or SPZ scan from Files. Each scan becomes a space you can enter."))
                        Button("Import scans…") { pickingFiles = true }.buttonStyle(.borderedProminent)
                            .disabled(model.busy || !model.prepared)
                    }
                    if model.busy || model.opening || (model.isImmersive && !model.renderStatus.ready && model.renderStatus.loadFailure == nil) {
                        ProgressView(model.isImmersive ? model.renderStatus.message : model.message)
                    } else {
                        Text(model.isImmersive ? model.renderStatus.message : model.message)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !model.prepared && !model.busy { Button("Retry library setup") { Task { await model.bootstrap() } } }
                    Text("Scans live in Files → On My Apple Vision Pro → Splativerse → Scans.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(red: 0.80, green: 0.90, blue: 0.98).opacity(0.22))
            .navigationTitle(model.isImmersive ? "Inside your scan" : "Spaces you can step inside")
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.splativersePLY, .splativerseSPZ, .splativerseSplat], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.importScans(urls) }
            case .failure(let error): model.issue = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await model.chooseDownloads(url) }
            case .failure(let error): model.issue = error.localizedDescription
            }
        }
        .alert("In Downloads, select Open", isPresented: $showingFolderInstructions) {
            Button("Continue to Files") { pickingFolder = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Go inside your Downloads folder in iCloud Drive or On My Apple Vision Pro. Then select Open in the upper-right corner to use that folder. Leave the individual files unselected. Splativerse will find and copy the scans automatically.")
        }
        .alert("Splativerse", isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {
            Button("OK", role: .cancel) { model.issue = nil }
        } message: { Text(model.issue ?? "") }
        .task { await model.bootstrap() }
        .onAppear { model.menuHidden = false }
        .onDisappear { if model.isImmersive { model.menuHidden = true } }
        .onChange(of: scenePhase) { _, phase in
            if !model.isImmersive { RenderControl.shared.setInteractionActive(phase == .active) }
            if phase == .active && model.prepared && !model.isImmersive { Task { await model.refresh() } }
        }
        .onOpenURL { url in Task { await model.importScans([url]) } }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your Splativerse folder is ready", systemImage: "folder.badge.plus").font(.title2)
            Text("Choose your Downloads folder in Files. Splativerse copies the PLY and SPZ scans it finds into its own Scans folder. Your originals stay in Downloads.")
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Go inside Downloads")
                    .font(.headline)
                Text("In Files, open Downloads in iCloud Drive or On My Apple Vision Pro.")
                    .font(.callout)
                Text("2. Select Open in the upper-right corner")
                    .font(.headline)
                Text("Leave the individual files unselected. Open confirms the folder; Splativerse finds and copies the scans automatically.")
                    .font(.callout)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Continue to Files…") { pickingFolder = true }.buttonStyle(.borderedProminent)
                Button("Set up later") { model.completeSetup() }
            }.disabled(model.busy)
        }.padding(22).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var navigationControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let scan = model.selected {
                BubbleRadiusControl(radius: scan.settings.bubbleRadius) { model.setBubbleRadius($0) }
                if model.renderStatus.bubbleRadius != scan.settings.bubbleRadius {
                    Text("Currently rendering at \(Int(model.renderStatus.bubbleRadius)) m. The requested radius is \(Int(scan.settings.bubbleRadius)) m.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Flight panel", isOn: Binding(get: { model.renderStatus.flightEnabled }, set: { value in
                    model.renderStatus.flightEnabled = value
                    RenderControl.shared.enqueue(.setFlightEnabled(value))
                })).disabled(!model.renderStatus.flightAvailable)
                Text(model.renderStatus.flightMessage).font(.callout).textSelection(.enabled)
                VStack(alignment: .leading,spacing: 10) {
                    Text("Panel placement").font(.headline)
                    Text("Pinch the low brass handle to reposition the panel. It turns radially to face your headset while held, then stays fixed when released. Flight pauses while placing.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Lower 5 cm") { RenderControl.shared.enqueue(.adjustFlightPanel(height: -0.05,distance: 0)) }
                        Button("Raise 5 cm") { RenderControl.shared.enqueue(.adjustFlightPanel(height: 0.05,distance: 0)) }
                    }.disabled(!model.renderStatus.flightEnabled)
                    HStack {
                        Button("Closer 5 cm") { RenderControl.shared.enqueue(.adjustFlightPanel(height: 0,distance: -0.05)) }
                        Button("Farther 5 cm") { RenderControl.shared.enqueue(.adjustFlightPanel(height: 0,distance: 0.05)) }
                    }.disabled(!model.renderStatus.flightEnabled)
                    Button("Bring panel here",systemImage: "arrow.down.forward.and.arrow.up.backward") {
                        RenderControl.shared.enqueue(.bringFlightPanelHere)
                    }
                }.disabled(!model.renderStatus.flightAvailable)
                Text("Pinch the metallic stick with either hand. Push forward or pull back to move along your current headset viewing direction, including up or down. Move the stick sideways to turn gradually left or right. Release to stop. The control adds yaw only; it never pitches or rolls your camera.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("6.5 cm full travel · up to 2 m/s along your view · 45°/s turning").font(.caption).foregroundStyle(.secondary)
            }
            Text("Walk naturally to explore. Use the controls to reach farther parts of the scan.").font(.callout)
            HStack {
                Button("Left", systemImage: "arrow.left") { step(right: -1) }
                Button("Forward", systemImage: "arrow.up") { step(forward: 1) }
                Button("Back", systemImage: "arrow.down") { step(forward: -1) }
                Button("Right", systemImage: "arrow.right") { step(right: 1) }
            }
            HStack {
                Button("Turn left 30°") { RenderControl.shared.enqueue(.turn(.pi / 6)) }
                Button("Turn right 30°") { RenderControl.shared.enqueue(.turn(-.pi / 6)) }
                Button("Return to start") { RenderControl.shared.enqueue(.recenter) }
            }
            HStack {
                Button("Up 25 cm") { step(up: 0.25) }
                Button("Down 25 cm") { step(up: -0.25) }
            }
            Button("Refresh distant scenery", systemImage: "arrow.clockwise") { RenderControl.shared.enqueue(.refreshBackground) }
            Text("Nearby splats stay live; distant scenery is a cached panorama. Release the radius slider to apply a change.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Steps: 1 metre · no collision mesh is inferred from the scan").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!model.renderStatus.ready)
    }
    private func step(forward: Float = 0, right: Float = 0, up: Float = 0) {
        RenderControl.shared.enqueue(.step(forward: forward, right: right, up: up))
    }
    private func enter(_ scan: ScanRecord) {
        model.opening = true; model.lastLoadFailure = nil
        Task {
            let request = await model.request(for: scan)
            model.activeRequest = request
            RenderControl.shared.begin(request.id)
            model.updateScanNavigation(request.id)
            switch await openImmersiveSpace(value: request) {
            case .opened: if model.activeRequest?.id == request.id { model.isImmersive = true }
            case .error: model.issue = "The immersive space could not open. Try again from the library."; model.lastLoadFailure = model.issue; model.activeRequest = nil
            case .userCancelled: model.lastLoadFailure = "Opening the immersive space was canceled by the system or user."; model.activeRequest = nil
            @unknown default: model.activeRequest = nil
            }
            model.opening = false
        }
    }
    private func leave() async {
        guard !model.closingImmersive else { return }
        model.closingImmersive = true
        if let id = model.activeRequest?.id { RenderControl.shared.stop(id) }
        await dismissImmersiveSpace()
        model.isImmersive = false; model.activeRequest = nil; model.closingImmersive = false
    }
}

private extension String { var pathExtension: String { (self as NSString).pathExtension } }

struct ScanDetail: View {
    let scan: ScanRecord
    let locked: Bool
    let save: (ScanSettings) -> Void
    @State private var settings: ScanSettings
    init(scan: ScanRecord, locked: Bool, save: @escaping (ScanSettings) -> Void) {
        self.scan = scan; self.locked = locked; self.save = save
        _settings = State(initialValue: scan.settings)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("WALK-THROUGH SPACE", systemImage: "visionpro").font(.caption).tracking(2)
            Text(scan.title).font(.largeTitle).bold().textSelection(.enabled)
            Text("Full Gaussian splats · light blue surroundings").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Picker("Source units", selection: $settings.metresPerUnit) {
                    Text("Metres").tag(Float(1)); Text("Centimetres").tag(Float(0.01)); Text("Millimetres").tag(Float(0.001))
                }
                Picker("Up direction", selection: $settings.upAxis) {
                    ForEach(ScanUpAxis.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Stepper("Floor adjustment: \(settings.floorOffset, specifier: "%.2f") m", value: $settings.floorOffset, in: -1000...1000, step: 0.25)
                Text("Entry is estimated near the densest scan region, with a local floor and nearby open-space check. This approximates a useful viewing position; the original camera position cannot be reliably recovered from splat geometry. Set the correct source units and up direction before entering.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(locked)
            if !locked {
                BubbleRadiusControl(radius: settings.bubbleRadius) { settings.bubbleRadius = $0 }
            }
        }
        .onChange(of: settings) { _, value in if value != scan.settings { save(value) } }
        .onChange(of: scan.settings) { _, value in settings = value }
    }
}


private struct BubbleRadiusControl: View {
    let radius: Float
    let apply: (Float) -> Void
    @State private var draft: Float
    @State private var editing = false
    init(radius: Float, apply: @escaping (Float) -> Void) {
        self.radius = radius; self.apply = apply
        _draft = State(initialValue: radius)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live detail radius: \(Int(draft)) m").font(.headline).monospacedDigit()
            Slider(value: $draft, in: BubbleConfiguration.radiusLimits, step: 60,
                label: { Text("Live detail radius") },
                minimumValueLabel: { Text("60 m") }, maximumValueLabel: { Text("360 m") },
                onEditingChanged: { active in
                    editing = active
                    if !active { apply(draft) }
                })
            .accessibilityValue("\(Int(draft)) metres")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))],alignment: .leading,spacing: 8) {
                ForEach([60, 120, 180, 240, 300, 360], id: \.self) { value in
                    Button("\(value) m") { draft = Float(value); apply(draft) }
                }
            }
            Text("Smaller radii draw fewer splats. Saved for this scan; the current view stays visible while a change is prepared.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: radius) { _, value in if !editing { draft = value } }
    }
}

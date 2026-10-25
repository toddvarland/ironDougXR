import Foundation
import Combine
@preconcurrency import ARKit
import RealityKit

@MainActor
final class ARViewModel: NSObject, ObservableObject {

    weak var arView: ARView?

    @Published var trackingStatusMessage: String = "Initializing…"
    @Published var isRelocalizing: Bool = false
    @Published var isReadyToSave: Bool = false
    @Published var showRecalibrationPrompt: Bool = false
    @Published var savedAnchors: [AnchorRecord] = []

    /// Markers placed since the last Save; they aren't on disk until the world map is.
    @Published private(set) var unsavedIDs: Set<UUID> = []

    var anchorCount: Int { savedAnchors.count }
    var hasUnsavedChanges: Bool { !unsavedIDs.isEmpty }

    private var liveEntities: [UUID: AnchorEntity] = [:]

    override init() {
        super.init()
        if CommandLine.arguments.contains("--forceRecalibrationPrompt") {
            showRecalibrationPrompt = true
        }
    }
    private var liveARAnchors: [UUID: ARAnchor] = [:]
    private var relocalizationTimer: Timer?

    // MARK: - Session

    func startSession() {
        let worldMap = PersistenceManager.loadWorldMap()

        // Drop records whose anchor isn't in the saved world map — they can never be restored
        let loaded = PersistenceManager.loadAnchorRecords()
        let mapAnchorIDs = worldMap.map(Self.anchorIDs(in:)) ?? []
        savedAnchors = Self.records(loaded, restorableFrom: mapAnchorIDs)
        if savedAnchors.count != loaded.count {
            PersistenceManager.save(anchorRecords: savedAnchors)
        }

        if worldMap != nil,
           let oldestDate = savedAnchors.map({ $0.timestamp }).min(),
           Date().timeIntervalSince(oldestDate) > 30 * 24 * 60 * 60 {
            showRecalibrationPrompt = true
        }

        arView?.session.run(makeARConfiguration(worldMap: worldMap))
    }

    static func records(_ records: [AnchorRecord], restorableFrom mapAnchorIDs: Set<UUID>) -> [AnchorRecord] {
        records.filter { mapAnchorIDs.contains($0.id) }
    }

    nonisolated static func anchorIDs(in worldMap: ARWorldMap) -> Set<UUID> {
        Set(worldMap.anchors.compactMap { $0.name.flatMap(UUID.init(uuidString:)) })
    }

    private func makeARConfiguration(worldMap: ARWorldMap? = nil) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = .sceneDepth
        }
        config.initialWorldMap = worldMap
        return config
    }

    // MARK: - Tap Handling

    func handleTap(at screenPoint: CGPoint) {
        guard let arView else { return }

        var results = arView.raycast(
            from: screenPoint,
            allowing: .existingPlaneGeometry,
            alignment: .any
        )
        if results.isEmpty {
            results = arView.raycast(
                from: screenPoint,
                allowing: .estimatedPlane,
                alignment: .any
            )
        }
        guard let hit = results.first else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }

        let anchorID = UUID()
        let arkitAnchor = ARAnchor(name: anchorID.uuidString, transform: hit.worldTransform)

        // Add metadata first so label is resolvable in attachMarker
        addUnsavedRecord(id: anchorID)

        arView.session.add(anchor: arkitAnchor)
        liveARAnchors[anchorID] = arkitAnchor
        attachMarker(to: arkitAnchor, in: arView, id: anchorID)

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    // MARK: - Marker Management

    /// Counts up from the highest existing "Mark N", so numbers are never reused.
    static func nextDefaultLabel(after records: [AnchorRecord]) -> String {
        let highest = records
            .compactMap { record -> Int? in
                guard record.label.hasPrefix("Mark ") else { return nil }
                return Int(record.label.dropFirst("Mark ".count))
            }
            .max() ?? 0
        return "Mark \(highest + 1)"
    }

    /// Adds a record in memory only; it's written to disk with the next successful Save.
    func addUnsavedRecord(id: UUID) {
        savedAnchors.append(AnchorRecord(
            id: id,
            label: Self.nextDefaultLabel(after: savedAnchors),
            timestamp: Date()
        ))
        unsavedIDs.insert(id)
    }

    /// Writes only records whose anchor is already in the saved world map.
    private func persistSavedRecords() {
        PersistenceManager.save(anchorRecords: savedAnchors.filter { !unsavedIDs.contains($0.id) })
    }

    /// Called once a world map is on disk; only anchors it actually contains become saved.
    func commitUnsavedRecords(inMap mapAnchorIDs: Set<UUID>) {
        unsavedIDs.subtract(mapAnchorIDs)
        persistSavedRecords()
    }

    func attachMarker(to anchor: ARAnchor, in arView: ARView, id: UUID) {
        let label = savedAnchors.first(where: { $0.id == id })?.label ?? "Mark"
        let anchorEntity = AnchorEntity(anchor: anchor)
        let markerEntity = MarkerEntity.make(label: label)
        anchorEntity.addChild(markerEntity)
        arView.scene.addAnchor(anchorEntity)
        liveEntities[id] = anchorEntity
    }

    func deleteAnchor(id: UUID) {
        if let entity = liveEntities[id] {
            arView?.scene.removeAnchor(entity)
            liveEntities.removeValue(forKey: id)
        }
        // Remove from the session too, so the next saved world map doesn't keep it
        if let arkitAnchor = liveARAnchors.removeValue(forKey: id) {
            arView?.session.remove(anchor: arkitAnchor)
        }
        savedAnchors.removeAll { $0.id == id }
        unsavedIDs.remove(id)
        persistSavedRecords()
    }

    func renameAnchor(id: UUID, label: String) {
        guard let index = savedAnchors.firstIndex(where: { $0.id == id }) else { return }
        savedAnchors[index] = AnchorRecord(
            id: id,
            label: label,
            timestamp: savedAnchors[index].timestamp
        )
        persistSavedRecords()

        // Re-attach the entity to refresh the label text in the scene
        if let arView,
           let entity = liveEntities[id],
           let arkitAnchor = liveARAnchors[id] {
            arView.scene.removeAnchor(entity)
            liveEntities.removeValue(forKey: id)
            attachMarker(to: arkitAnchor, in: arView, id: id)
        }
    }

    func clearAllAnchors() {
        liveEntities.values.forEach { arView?.scene.removeAnchor($0) }
        liveARAnchors.values.forEach { arView?.session.remove(anchor: $0) }
        liveEntities.removeAll()
        liveARAnchors.removeAll()
        savedAnchors.removeAll()
        unsavedIDs.removeAll()
        PersistenceManager.clearAll()
    }

    // MARK: - World Map Save

    func saveWorldMap() {
        arView?.session.getCurrentWorldMap { [weak self] worldMap, error in
            guard let worldMap else {
                print("ARViewModel: world map unavailable — \(error?.localizedDescription ?? "unknown")")
                return
            }
            // getCurrentWorldMap completion is called on the main thread
            MainActor.assumeIsolated {
                do {
                    try PersistenceManager.save(worldMap: worldMap)
                } catch {
                    print("ARViewModel: failed to save world map — \(error)")
                    return
                }
                self?.commitUnsavedRecords(inMap: Self.anchorIDs(in: worldMap))
                self?.trackingStatusMessage = "Saved ✓"
                // Reset banner after 2 seconds
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    if self?.trackingStatusMessage == "Saved ✓" {
                        self?.trackingStatusMessage = "Ready"
                    }
                }
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension ARViewModel: ARSessionDelegate {

    nonisolated func session(
        _ session: ARSession,
        cameraDidChangeTrackingState camera: ARCamera
    ) {
        let message: String
        let ready: Bool
        let relocalizing: Bool

        switch camera.trackingState {
        case .normal:
            message = "Ready"
            ready = true
            relocalizing = false
        case .limited(.relocalizing):
            message = "Point camera at the saved area to restore markers…"
            ready = false
            relocalizing = true
        case .limited(.initializing):
            message = "Initializing…"
            ready = false
            relocalizing = false
        case .limited(.excessiveMotion):
            message = "Move slower"
            ready = false
            relocalizing = false
        case .limited(.insufficientFeatures):
            message = "Need more light or texture"
            ready = false
            relocalizing = false
        case .notAvailable:
            message = "Tracking unavailable"
            ready = false
            relocalizing = false
        @unknown default:
            message = ""
            ready = false
            relocalizing = false
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.trackingStatusMessage = message
            self.isReadyToSave = ready
            self.isRelocalizing = relocalizing

            if relocalizing {
                if self.relocalizationTimer == nil {
                    self.relocalizationTimer = Timer.scheduledTimer(
                        withTimeInterval: 30,
                        repeats: false
                    ) { [weak self] _ in
                        Task { @MainActor in
                            self?.trackingStatusMessage = "Insufficient environment calibration"
                            self?.showRecalibrationPrompt = true
                        }
                    }
                }
            } else {
                self.relocalizationTimer?.invalidate()
                self.relocalizationTimer = nil
            }
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor [weak self] in
            guard let self, let arView = self.arView else { return }
            for anchor in anchors {
                guard
                    let name = anchor.name,
                    let id = UUID(uuidString: name),
                    self.savedAnchors.contains(where: { $0.id == id }),
                    self.liveEntities[id] == nil
                else { continue }
                self.liveARAnchors[id] = anchor
                self.attachMarker(to: anchor, in: arView, id: id)
            }
        }
    }
}

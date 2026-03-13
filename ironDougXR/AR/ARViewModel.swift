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
    @Published var anchorCount: Int = 0

    var savedAnchors: [AnchorRecord] = []

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
        savedAnchors = PersistenceManager.loadAnchorRecords()
        anchorCount = savedAnchors.count

        let worldMap = PersistenceManager.loadWorldMap()

        if worldMap != nil,
           let oldestDate = savedAnchors.map({ $0.timestamp }).min(),
           Date().timeIntervalSince(oldestDate) > 30 * 24 * 60 * 60 {
            showRecalibrationPrompt = true
        }

        arView?.session.run(makeARConfiguration(worldMap: worldMap))
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

        // Save metadata first so label is resolvable in attachMarker
        let record = AnchorRecord(
            id: anchorID,
            label: "Mark \(savedAnchors.count + 1)",
            timestamp: Date()
        )
        savedAnchors.append(record)
        PersistenceManager.save(anchorRecords: savedAnchors)

        arView.session.add(anchor: arkitAnchor)
        liveARAnchors[anchorID] = arkitAnchor
        attachMarker(to: arkitAnchor, in: arView, id: anchorID)

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    // MARK: - Marker Management

    func attachMarker(to anchor: ARAnchor, in arView: ARView, id: UUID) {
        let label = savedAnchors.first(where: { $0.id == id })?.label ?? "Mark"
        let anchorEntity = AnchorEntity(anchor: anchor)
        let markerEntity = MarkerEntity.make(label: label)
        anchorEntity.addChild(markerEntity)
        arView.scene.addAnchor(anchorEntity)
        liveEntities[id] = anchorEntity
        anchorCount = liveEntities.count
    }

    func deleteAnchor(id: UUID) {
        if let entity = liveEntities[id] {
            arView?.scene.removeAnchor(entity)
            liveEntities.removeValue(forKey: id)
        }
        liveARAnchors.removeValue(forKey: id)
        savedAnchors.removeAll { $0.id == id }
        PersistenceManager.save(anchorRecords: savedAnchors)
        anchorCount = liveEntities.count
    }

    func renameAnchor(id: UUID, label: String) {
        guard let index = savedAnchors.firstIndex(where: { $0.id == id }) else { return }
        savedAnchors[index] = AnchorRecord(
            id: id,
            label: label,
            timestamp: savedAnchors[index].timestamp
        )
        PersistenceManager.save(anchorRecords: savedAnchors)

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
        liveEntities.removeAll()
        liveARAnchors.removeAll()
        savedAnchors.removeAll()
        PersistenceManager.clearAll()
        anchorCount = 0
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
                PersistenceManager.save(worldMap: worldMap)
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

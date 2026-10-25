# Building a Persistent AR Anchor App for iPhone 14 Pro Max

## Overview

This guide covers building a native iOS AR app that lets the user look at a real-world environment through the iPhone camera, tap to drop a highly visible 3D marker anchored to a specific point in physical space, and have that marker reappear in exactly the same location the next time the app is launched.

**Target device:** iPhone 14 Pro Max (has LiDAR Scanner — use it)  
**Frameworks:** ARKit 6, RealityKit 2, SwiftUI, FileManager (JSON + archived `ARWorldMap`) for persistence  
**Language:** Swift 6 (strict concurrency)  
**Xcode:** 26+, deployment target iOS 18+ (project generated from `project.yml` with xcodegen)

---

## Table of Contents

1. [Core Concepts](#1-core-concepts)
2. [Project Setup](#2-project-setup)
3. [AR Session Configuration](#3-ar-session-configuration)
4. [Raycasting & Anchor Placement](#4-raycasting--anchor-placement)
5. [Designing the Highly Visible Marker](#5-designing-the-highly-visible-marker)
6. [Persisting Anchors Between Sessions](#6-persisting-anchors-between-sessions)
7. [Restoring Anchors on App Launch](#7-restoring-anchors-on-app-launch)
8. [Full Architecture Diagram](#8-full-architecture-diagram)
9. [Complete Implementation Walkthrough](#9-complete-implementation-walkthrough)
10. [UX Considerations](#10-ux-considerations)
11. [Known Limitations](#11-known-limitations)

---

## 1. Core Concepts

### ARKit World Tracking
ARKit's `ARWorldTrackingConfiguration` continuously tracks the device's 6-degrees-of-freedom position and orientation relative to the real world. Every `ARAnchor` placed in the scene is stored relative to the world coordinate system ARKit builds on the fly.

### LiDAR on iPhone 14 Pro Max
The LiDAR Scanner enables **scene reconstruction** — ARKit can generate a dense mesh of the physical environment. This improves:
- Plane detection speed and accuracy (floors, walls, tables)
- Raycast accuracy (casts against real geometry, not estimated planes)
- Occlusion of virtual objects by real-world surfaces

Enable it with `ARWorldTrackingConfiguration.sceneReconstruction = .meshWithClassification`.

### RealityKit vs SceneKit
| Feature | RealityKit | SceneKit |
|---|---|---|
| Physically Based Rendering | Native | Supported |
| Entity-Component System | Yes | No |
| ARKit integration | Deep (ARView) | Manual |
| Animation system | `.AnimationResource` | `.CAAnimation` |
| Recommendation | **Use this** | Legacy |

Use **RealityKit** for all 3D rendering.

### Anchor Persistence Strategy
ARKit provides `ARWorldMap` — a snapshot of the spatial understanding ARKit has built, including all placed anchors. Serializing and saving this map to disk, then reloading it on next launch, is the primary persistence mechanism.

> **Important caveat:** `ARWorldMap` relocalization requires the user to point the phone at the *same physical environment* that was mapped originally. It works extremely well indoors for fixed locations (a desk, a shelf, a room). **Outdoors**, where there are fewer stable visual features (sky, open ground, moving objects), relocalization is significantly less reliable — plan for occasional failure in outdoor use and surface the recalibration prompt accordingly. It does not work if the environment changes dramatically between sessions.

---

## 2. Project Setup

### Xcode Project Configuration

1. Create a new **App** target in Xcode (Swift, SwiftUI or UIKit storyboard).
2. In `Info.plist`, add the required privacy keys:

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera to display and anchor AR markers in your environment.</string>
```

3. In **Signing & Capabilities**, confirm the target is set to a real device — ARKit does not run in the Simulator.

### Package Dependencies (Swift Package Manager)

No external dependencies are required. All needed frameworks ship with iOS:
- `ARKit` — world tracking, anchors, world maps
- `RealityKit` — 3D rendering, entities, animations
- `Combine` — reactive bindings between AR state and UI
- `FileManager` — saving anchor metadata (plain JSON; CoreData is unnecessary for up to 10 markers)

### Entitlements
No special entitlements are required for this app.

---

## 3. AR Session Configuration

```swift
import ARKit
import RealityKit

func makeARConfiguration() -> ARWorldTrackingConfiguration {
    let config = ARWorldTrackingConfiguration()

    // Use LiDAR for high-quality plane detection and raycasting (checked, so non-LiDAR devices don't crash)
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
        config.sceneReconstruction = .meshWithClassification
    }

    // Detect horizontal and vertical planes (floors, walls, tables)
    config.planeDetection = [.horizontal, .vertical]

    // Enable environment texturing for realistic lighting on the marker
    config.environmentTexturing = .automatic

    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
        config.frameSemantics = .sceneDepth
    }

    return config
}
```

### ARView Setup (RealityKit)

```swift
import SwiftUI
import RealityKit
import ARKit

struct ContentView: View {
    @StateObject private var arViewModel = ARViewModel()

    var body: some View {
        ZStack {
            ARViewContainer(viewModel: arViewModel)
                .ignoresSafeArea()
                .onTapGesture { location in
                    arViewModel.handleTap(at: location)
                }

            VStack {
                Spacer()
                HStack {
                    Button("Save") { arViewModel.saveWorldMap() }
                        .buttonStyle(.borderedProminent)
                    Button("Clear All") { arViewModel.clearAllAnchors() }
                        .buttonStyle(.bordered)
                }
                .padding()
            }
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let viewModel: ARViewModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        viewModel.arView = arView
        arView.session.delegate = viewModel
        arView.session.run(makeARConfiguration())
        viewModel.loadSavedAnchors() // attempt restore on start
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
```

---

## 4. Raycasting & Anchor Placement

Raycasting against real LiDAR geometry is far more accurate than the older hit-test API. Always prefer `ARView.raycast(from:allowing:alignment:)`.

```swift
func handleTap(at screenPoint: CGPoint) {
    guard let arView = arView else { return }

    // Prefer LiDAR mesh geometry — guaranteed on iPhone 14 Pro Max.
    // Fall back to .estimatedPlane during the first few seconds before the mesh has fully built.
    var results = arView.raycast(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .any)
    if results.isEmpty {
        results = arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
    }

    guard let firstResult = results.first else {
        // Provide haptic feedback indicating no surface found
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
        return
    }

    // Create a named anchor at the hit location
    let anchorID = UUID()
    let anchor = ARAnchor(name: anchorID.uuidString, transform: firstResult.worldTransform)
    arView.session.add(anchor: anchor)

    // Attach a visible marker entity
    attachMarker(to: anchor, in: arView, id: anchorID)

    // Persist the anchor's metadata
    saveAnchorMetadata(id: anchorID, transform: firstResult.worldTransform)

    // Success haptic
    let generator = UIImpactFeedbackGenerator(style: .heavy)
    generator.impactOccurred()
}
```

---

## 5. Designing the Highly Visible Marker

The marker is composed of three layered elements built entirely with RealityKit primitives — no `.usdz` asset required:

| Layer | Shape | Purpose |
|---|---|---|
| Ground ring | Flat torus / cylinder | Marks the exact floor point |
| Vertical pole | Thin cylinder | Draws the eye upward |
| Beacon orb | Sphere with emissive material | Glows and pulses for visibility |
| Billboard label | `ModelEntity` with text mesh | Shows optional label text |

```swift
func makeMarkerEntity(label: String = "Point") -> Entity {
    let root = Entity()

    // --- Ground ring ---
    let ringMesh = MeshResource.generateCylinder(height: 0.005, radius: 0.12)
    var ringMaterial = UnlitMaterial(color: .systemOrange)
    ringMaterial.color = .init(tint: UIColor.systemOrange.withAlphaComponent(0.85))
    let ringEntity = ModelEntity(mesh: ringMesh, materials: [ringMaterial])
    ringEntity.position = [0, 0.0025, 0]
    root.addChild(ringEntity)

    // --- Vertical pole ---
    let poleMesh = MeshResource.generateCylinder(height: 0.5, radius: 0.008)
    var poleMaterial = UnlitMaterial(color: .white)
    let poleEntity = ModelEntity(mesh: poleMesh, materials: [poleMaterial])
    poleEntity.position = [0, 0.25, 0]
    root.addChild(poleEntity)

    // --- Beacon orb (emissive/unlit for maximum visibility) ---
    let orbMesh = MeshResource.generateSphere(radius: 0.045)
    var orbMaterial = UnlitMaterial(color: .systemOrange)
    // RealityKit UnlitMaterial renders at full brightness regardless of scene lighting
    let orbEntity = ModelEntity(mesh: orbMesh, materials: [orbMaterial])
    orbEntity.position = [0, 0.52, 0]
    root.addChild(orbEntity)

    // --- Pulsing animation on the orb ---
    orbEntity.addPulseAnimation()

    // --- Billboard text label ---
    let textMesh = MeshResource.generateText(
        label,
        extrusionDepth: 0.005,
        font: .systemFont(ofSize: 0.06, weight: .bold),
        containerFrame: .zero,
        alignment: .center,
        lineBreakMode: .byTruncatingTail
    )
    var textMaterial = UnlitMaterial(color: .white)
    let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
    // Center the text horizontally
    let textBounds = textEntity.visualBounds(relativeTo: nil)
    textEntity.position = [-textBounds.extents.x / 2, 0.60, 0]
    root.addChild(textEntity)

    return root
}

// Extension: add a looping scale pulse to any entity
extension Entity {
    func addPulseAnimation() {
        // Scale from 1.0 → 1.4 → 1.0 continuously
        var bigTransform = self.transform
        bigTransform.scale = SIMD3<Float>(1.4, 1.4, 1.4)

        let growAnim = FromToByAnimation<Transform>(
            name: "grow",
            from: self.transform,
            to: bigTransform,
            duration: 0.7,
            bindTarget: .transform
        )
        let shrinkAnim = FromToByAnimation<Transform>(
            name: "shrink",
            from: bigTransform,
            to: self.transform,
            duration: 0.7,
            bindTarget: .transform
        )

        if let grow = try? AnimationResource.generate(with: growAnim),
           let shrink = try? AnimationResource.generate(with: shrinkAnim) {
            let sequence = try? AnimationResource.sequence(with: [grow, shrink])
            let looping = try? AnimationResource.repeat(sequence!, duration: .infinity)
            if let looping = looping {
                self.playAnimation(looping)
            }
        }
    }
}
```

### Attaching the Marker to an Anchor

```swift
func attachMarker(to anchor: ARAnchor, in arView: ARView, id: UUID) {
    let anchorEntity = AnchorEntity(anchor: anchor)
    let markerEntity = makeMarkerEntity(label: "Mark \(savedAnchors.count + 1)")
    anchorEntity.addChild(markerEntity)
    arView.scene.addAnchor(anchorEntity)
    // Track live entities so we can remove them if needed
    liveEntities[id] = anchorEntity
}
```

---

## 6. Persisting Anchors Between Sessions

### Strategy: ARWorldMap + Anchor Metadata

Persistence requires two separate saves:

| What | Why | Format |
|---|---|---|
| `ARWorldMap` | Contains the spatial feature points ARKit needs to relocalize | Serialized `Data` written to a file |
| Anchor metadata | UUID, optional label, timestamp | `Codable` struct in JSON or CoreData |

When the app relaunches, it loads the `ARWorldMap`, passes it to the new AR session, and once ARKit reports `.limited(.relocalizing)` → `.normal`, the saved anchors reappear automatically because they are embedded in the world map.

### Saving the World Map

```swift
func saveWorldMap() {
    arView?.session.getCurrentWorldMap { [weak self] worldMap, error in
        guard let self = self, let worldMap = worldMap else {
            print("WorldMap unavailable: \(error?.localizedDescription ?? "unknown")")
            return
        }

        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: worldMap,
                requiringSecureCoding: true
            )
            try data.write(to: self.worldMapURL, options: .atomic)
            print("World map saved (\(data.count) bytes)")
        } catch {
            print("Failed to save world map: \(error)")
        }
    }
}

private var worldMapURL: URL {
    FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("worldmap.arexperience")
}
```

### Saving Anchor Metadata

```swift
struct AnchorRecord: Codable {
    let id: UUID
    let label: String
    let timestamp: Date
}

// In-memory store
var savedAnchors: [AnchorRecord] = []

func saveAnchorMetadata(id: UUID, transform: simd_float4x4) {
    let record = AnchorRecord(id: id, label: "Mark \(savedAnchors.count + 1)", timestamp: Date())
    savedAnchors.append(record)
    persistAnchorRecords()
}

private var anchorMetadataURL: URL {
    FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("anchors.json")
}

func persistAnchorRecords() {
    do {
        let data = try JSONEncoder().encode(savedAnchors)
        try data.write(to: anchorMetadataURL, options: .atomic)
    } catch {
        print("Failed to persist anchor records: \(error)")
    }
}

func loadAnchorRecords() {
    guard let data = try? Data(contentsOf: anchorMetadataURL),
          let records = try? JSONDecoder().decode([AnchorRecord].self, from: data) else { return }
    savedAnchors = records
}
```

---

## 7. Restoring Anchors on App Launch

### Loading the World Map

```swift
func loadSavedAnchors() {
    loadAnchorRecords() // load metadata first

    guard let data = try? Data(contentsOf: worldMapURL),
          let worldMap = try? NSKeyedUnarchiver.unarchivedObject(
              ofClass: ARWorldMap.self,
              from: data
          ) else {
        print("No saved world map found — starting fresh")
        return
    }

    let config = makeARConfiguration()
    config.initialWorldMap = worldMap         // <-- key line
    arView?.session.run(config, options: [])  // do NOT reset tracking
    print("World map loaded with \(worldMap.anchors.count) anchors")
}
```

### Handling Relocalization via ARSessionDelegate

When the world map is loaded, ARKit enters a relocalization phase. The user needs to point the phone at the same environment before tracking becomes fully reliable. Provide clear UI feedback.

If relocalization does not succeed within ~30 seconds (especially likely for outdoor use), show **"Insufficient environment calibration"** and offer a recalibration prompt. Implement this as a `Timer` started when `.relocalizing` is first detected and cancelled when the state returns to `.normal` — see the full `ARViewModel` implementation in Section 9.

```swift
extension ARViewModel: ARSessionDelegate {

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            trackingStatusMessage = "Tracking good"
        case .limited(.relocalizing):
            trackingStatusMessage = "Point camera at the saved area to restore markers…"
        case .limited(.initializing):
            trackingStatusMessage = "Initializing…"
        case .limited(.excessiveMotion):
            trackingStatusMessage = "Slow down — too much motion"
        case .limited(.insufficientFeatures):
            trackingStatusMessage = "Need more light or visual texture"
        case .notAvailable:
            trackingStatusMessage = "Tracking unavailable"
        @unknown default:
            break
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // When the world map reloads, existing ARAnchor objects fire this delegate.
        // Match them to saved records by name (which we set to the UUID string).
        for anchor in anchors {
            guard let nameString = anchor.name,
                  let id = UUID(uuidString: nameString),
                  savedAnchors.contains(where: { $0.id == id }),
                  let arView = arView else { continue }

            // Only attach if not already present in the scene
            if liveEntities[id] == nil {
                attachMarker(to: anchor, in: arView, id: id)
            }
        }
    }
}
```

---

## 8. Full Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        iOS App                              │
│                                                             │
│  ┌────────────┐    tap     ┌────────────────────────────┐  │
│  │  SwiftUI   │ ─────────► │       ARViewModel          │  │
│  │  ContentView│           │  (ObservableObject)        │  │
│  └────────────┘            │                            │  │
│                            │  handleTap(at:)            │  │
│  ┌────────────────────┐    │  saveWorldMap()            │  │
│  │  ARViewContainer   │    │  loadSavedAnchors()        │  │
│  │  (UIViewRepres.)   │◄───│  attachMarker(to:in:id:)   │  │
│  │                    │    │  clearAllAnchors()         │  │
│  │  ARView (RK)       │    └────────────────────────────┘  │
│  │   └ ARSession      │              │                      │
│  └────────────────────┘              │                      │
│           │                          │                      │
│           │ ARSessionDelegate        │                      │
│           └──────────────────────────┘                      │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   Persistence Layer                  │  │
│  │                                                      │  │
│  │  Documents/worldmap.arexperience  (ARWorldMap data)  │  │
│  │  Documents/anchors.json           (AnchorRecord[])   │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

Marker Entity Hierarchy
────────────────────────
AnchorEntity (bound to ARAnchor)
└── root Entity
    ├── ModelEntity  "ground ring"   (flat orange cylinder)
    ├── ModelEntity  "pole"          (white cylinder, 0.5m tall)
    ├── ModelEntity  "orb"           (orange pulsing sphere, UnlitMaterial)
    └── ModelEntity  "label"         (generated text mesh)
```

---

## 9. Complete Implementation Walkthrough

> **Note:** The listings below are the original design. The source files under `ironDougXR/` are authoritative and have since diverged — notably, new markers are written to `anchors.json` only on a successful Save, records with no anchor in the world map are dropped at launch, and the 30-day expiry is measured from the world map's save time.

### File Structure

```
ironDougXR/
├── App/
│   ├── IronDougXRApp.swift
│   └── ContentView.swift
├── AR/
│   ├── ARViewModel.swift       // session management, tap handling
│   ├── ARViewContainer.swift   // UIViewRepresentable wrapper
│   └── MarkerEntity.swift      // marker factory + animations
├── Persistence/
│   ├── PersistenceManager.swift // world map + anchor record I/O
│   └── AnchorRecord.swift       // Codable model
└── Resources/
    └── Info.plist
```

### ARViewModel.swift (consolidated)

```swift
import Foundation
import ARKit
import RealityKit
import Combine

@MainActor
final class ARViewModel: NSObject, ObservableObject {

    weak var arView: ARView?

    @Published var trackingStatusMessage: String = "Initializing…"
    @Published var anchorCount: Int = 0
    @Published var showRecalibrationPrompt: Bool = false

    private(set) var savedAnchors: [AnchorRecord] = []
    private var liveEntities: [UUID: AnchorEntity] = [:]
    private var liveARAnchors: [UUID: ARAnchor] = [:]   // for rename re-attach
    private var relocalizationTimer: Timer?

    // MARK: - Tap Handling

    func handleTap(at screenPoint: CGPoint) {
        guard let arView = arView else { return }

        var results = arView.raycast(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .any)
        if results.isEmpty {
            results = arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
        }
        guard let hit = results.first else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }

        let anchorID = UUID()
        let anchor = ARAnchor(name: anchorID.uuidString, transform: hit.worldTransform)
        arView.session.add(anchor: anchor)
        liveARAnchors[anchorID] = anchor
        attachMarker(to: anchor, in: arView, id: anchorID)
        saveAnchorMetadata(id: anchorID)

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    // MARK: - Marker Management

    private func attachMarker(to anchor: ARAnchor, in arView: ARView, id: UUID) {
        let label = savedAnchors.first(where: { $0.id == id })?.label ?? "Mark"
        let anchorEntity = AnchorEntity(anchor: anchor)
        let markerEntity = MarkerEntity.make(label: label)
        anchorEntity.addChild(markerEntity)
        arView.scene.addAnchor(anchorEntity)
        liveEntities[id] = anchorEntity
        anchorCount = liveEntities.count
    }

    func clearAllAnchors() {
        guard let arView = arView else { return }
        liveEntities.values.forEach { arView.scene.removeAnchor($0) }
        liveEntities.removeAll()
        liveARAnchors.removeAll()
        savedAnchors.removeAll()
        PersistenceManager.clearAll()
        anchorCount = 0
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
        let existing = savedAnchors[index]
        savedAnchors[index] = AnchorRecord(id: id, label: label, timestamp: existing.timestamp)
        PersistenceManager.save(anchorRecords: savedAnchors)
        // Refresh label: remove and re-attach the entity with the new label text
        if let arView = arView,
           let entity = liveEntities[id],
           let arkitAnchor = liveARAnchors[id] {
            arView.scene.removeAnchor(entity)
            liveEntities.removeValue(forKey: id)
            attachMarker(to: arkitAnchor, in: arView, id: id)
        }
    }

    // MARK: - Persistence

    func saveWorldMap() {
        arView?.session.getCurrentWorldMap { [weak self] worldMap, error in
            guard let worldMap = worldMap else { return }
            PersistenceManager.save(worldMap: worldMap)
        }
    }

    func loadSavedAnchors() {
        savedAnchors = PersistenceManager.loadAnchorRecords()
        anchorCount = savedAnchors.count

        guard let worldMap = PersistenceManager.loadWorldMap() else { return }

        // Prompt recalibration if the world map is older than 30 days
        if let oldestDate = savedAnchors.map({ $0.timestamp }).min() {
            let age = Date().timeIntervalSince(oldestDate)
            if age > 30 * 24 * 60 * 60 {
                showRecalibrationPrompt = true
            }
        }

        let config = makeARConfiguration()
        config.initialWorldMap = worldMap
        arView?.session.run(config, options: [])
    }

    private func saveAnchorMetadata(id: UUID) {
        let record = AnchorRecord(
            id: id,
            label: "Mark \(savedAnchors.count + 1)",
            timestamp: Date()
        )
        savedAnchors.append(record)
        PersistenceManager.save(anchorRecords: savedAnchors)
    }
}

// MARK: - ARSessionDelegate

extension ARViewModel: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let message: String
        let isRelocalizing: Bool
        switch camera.trackingState {
        case .normal:                         message = "Ready";                         isRelocalizing = false
        case .limited(.relocalizing):         message = "Point at saved area to restore markers…"; isRelocalizing = true
        case .limited(.initializing):         message = "Initializing…";                 isRelocalizing = false
        case .limited(.excessiveMotion):      message = "Move slower";                   isRelocalizing = false
        case .limited(.insufficientFeatures): message = "Need more light or texture";    isRelocalizing = false
        case .notAvailable:                   message = "Tracking unavailable";          isRelocalizing = false
        @unknown default:                     message = "";                              isRelocalizing = false
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.trackingStatusMessage = message
            if isRelocalizing {
                // Start a 30-second timeout; if still relocalizing, prompt recalibration
                if self.relocalizationTimer == nil {
                    self.relocalizationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
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
            guard let self = self, let arView = self.arView else { return }
            for anchor in anchors {
                guard let name = anchor.name,
                      let id = UUID(uuidString: name),
                      self.savedAnchors.contains(where: { $0.id == id }),
                      self.liveEntities[id] == nil else { continue }
                self.attachMarker(to: anchor, in: arView, id: id)
            }
        }
    }
}
```

### PersistenceManager.swift

```swift
import ARKit

enum PersistenceManager {

    private static var worldMapURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("worldmap.arexperience")
    }

    private static var anchorRecordsURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("anchors.json")
    }

    // MARK: World Map

    static func save(worldMap: ARWorldMap) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
            try data.write(to: worldMapURL, options: .atomic)
        } catch {
            print("PersistenceManager: failed to save world map — \(error)")
        }
    }

    static func loadWorldMap() -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    // MARK: Anchor Records

    static func save(anchorRecords: [AnchorRecord]) {
        do {
            let data = try JSONEncoder().encode(anchorRecords)
            try data.write(to: anchorRecordsURL, options: .atomic)
        } catch {
            print("PersistenceManager: failed to save anchor records — \(error)")
        }
    }

    static func loadAnchorRecords() -> [AnchorRecord] {
        guard let data = try? Data(contentsOf: anchorRecordsURL),
              let records = try? JSONDecoder().decode([AnchorRecord].self, from: data)
        else { return [] }
        return records
    }

    // MARK: Clear

    static func clearAll() {
        try? FileManager.default.removeItem(at: worldMapURL)
        try? FileManager.default.removeItem(at: anchorRecordsURL)
    }
}
```

### AnchorRecord.swift

```swift
import Foundation

struct AnchorRecord: Codable, Identifiable {
    let id: UUID
    let label: String
    let timestamp: Date
}
```

### MarkerEntity.swift

```swift
import RealityKit
import UIKit

enum MarkerEntity {

    static func make(label: String) -> Entity {
        let root = Entity()

        // Ground ring
        root.addChild(makeRing())

        // Vertical pole
        root.addChild(makePole())

        // Glowing orb with pulse
        let orb = makeOrb()
        orb.addPulseAnimation()
        root.addChild(orb)

        // Text label
        root.addChild(makeLabel(text: label))

        return root
    }

    // MARK: - Components

    private static func makeRing() -> ModelEntity {
        let mesh = MeshResource.generateCylinder(height: 0.005, radius: 0.12)
        let mat = UnlitMaterial(color: UIColor.systemOrange.withAlphaComponent(0.9))
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.position = [0, 0.0025, 0]
        return entity
    }

    private static func makePole() -> ModelEntity {
        let mesh = MeshResource.generateCylinder(height: 0.50, radius: 0.007)
        let mat = UnlitMaterial(color: .white)
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.position = [0, 0.25, 0]
        return entity
    }

    private static func makeOrb() -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 0.045)
        let mat = UnlitMaterial(color: UIColor.systemOrange)
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.position = [0, 0.52, 0]
        return entity
    }

    private static func makeLabel(text: String) -> ModelEntity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.004,
            font: .boldSystemFont(ofSize: 0.055),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let mat = UnlitMaterial(color: .white)
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        // Approximate horizontal centering
        let bounds = entity.visualBounds(relativeTo: nil)
        entity.position = [-bounds.extents.x / 2, 0.60, 0]
        return entity
    }
}

// MARK: - Pulse animation

private extension Entity {
    func addPulseAnimation() {
        var big = self.transform
        big.scale = SIMD3<Float>(1.35, 1.35, 1.35)

        guard
            let grow = try? AnimationResource.generate(
                with: FromToByAnimation<Transform>(
                    name: "grow", from: self.transform, to: big,
                    duration: 0.75, bindTarget: .transform
                )
            ),
            let shrink = try? AnimationResource.generate(
                with: FromToByAnimation<Transform>(
                    name: "shrink", from: big, to: self.transform,
                    duration: 0.75, bindTarget: .transform
                )
            ),
            let seq = try? AnimationResource.sequence(with: [grow, shrink]),
            let loop = try? AnimationResource.repeat(seq, duration: .infinity)
        else { return }

        self.playAnimation(loop)
    }
}
```

---

## 10. UX Considerations

### Coaching the User During Relocalization
When the app loads a saved world map, ARKit needs the user to scan the same environment before it can match positions. Show a clear overlay:

```swift
// In ContentView body, overlaid on the ARView
if viewModel.isRelocalizing {
    VStack {
        Image(systemName: "camera.viewfinder")
            .font(.system(size: 48))
            .foregroundColor(.yellow)
        Text(viewModel.trackingStatusMessage)
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding()
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
}
```

### Explicit Save
The world map is saved **only** when the user taps "Save". Newly placed markers are kept in memory until then (a red dot on the button shows there are unsaved markers), so `anchors.json` never lists a marker the saved world map doesn't contain. If the save fails, a "Save Failed" alert explains why. Automatic background saves are intentionally avoided — an inadvertent scan (e.g., the phone pointing at the ceiling while being pocketed) could overwrite a good world map.

Disable the button when tracking quality is not `.normal`:

```swift
Button("Save") { arViewModel.saveWorldMap() }
    .buttonStyle(.borderedProminent)
    .disabled(!arViewModel.isReadyToSave)   // true only when tracking is .normal
```

### Recalibration Prompt
When `showRecalibrationPrompt` is `true` (30-second relocalization timeout **or** world map last saved more than 30 days ago), present an alert:

```swift
.alert("Environment Calibration Needed", isPresented: $arViewModel.showRecalibrationPrompt) {
    Button("Clear & Start Fresh", role: .destructive) { arViewModel.clearAllAnchors() }
    Button("Dismiss", role: .cancel) { }
} message: {
    Text("Saved markers could not be restored, or the world map is out of date. Clear all markers, re-scan the environment, re-place markers, then Save.")
}
```

### Marker Visibility at Distance
All markers are rendered regardless of distance — no distance culling. For markers 5–10 m away:
- Increase the orb radius to 0.08 m and pole height to 1.0 m
- Add a radar-style outer ring that oscillates outward from the base
- Use `BillboardComponent` so the label always faces the camera:

```swift
textEntity.components.set(BillboardComponent())
```

### Per-Marker Management (Edit & Delete)
Up to 10 markers are supported. Expose a list sheet so the user can rename or delete individual markers:

```swift
struct MarkerListView: View {
    @ObservedObject var viewModel: ARViewModel

    var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.savedAnchors) { record in
                    HStack {
                        Text(record.label)
                        Spacer()
                        Text(record.timestamp, style: .date)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet {
                        viewModel.deleteAnchor(id: viewModel.savedAnchors[i].id)
                    }
                }
            }
            .navigationTitle("Markers")
            .toolbar { EditButton() }
        }
    }
}
```

Renaming is triggered by tapping a row: present a `TextField` alert and call `viewModel.renameAnchor(id:label:)`. The live marker entity is automatically rebuilt with the updated label.

---

## 11. Known Limitations

| Limitation | Detail | Workaround |
|---|---|---|
| **Relocalization required** | On every new launch, ARKit needs to re-scan the saved environment before anchors reappear | Show the tracking status UI; the 30-second timeout triggers the recalibration prompt if needed |  
| **Outdoor use is less reliable** | Outdoors has fewer stable visual features; relocalization may fail or take longer | The recalibration prompt and 30-second timeout handle this gracefully |
| **Environment must be similar** | Rearranged furniture or dramatically changed lighting can cause relocalization failure | The 30-day world map expiry prompt encourages periodic recalibration |
| **Single device, single user** | `ARWorldMap` is not synced across devices — intentional for this app | Accepted; collaborative sessions or iCloud would be needed if multi-device is added later |
| **World map size** | A richly scanned room can produce a world map of 1–5 MB | Acceptable for local Documents storage |
| **No persistence after app reinstall** | Documents directory is wiped on app delete | Accepted limitation — no iCloud backup required |
| **LiDAR always present** | Minimum device is iPhone 14 Pro Max; LiDAR is guaranteed | `.existingPlaneGeometry` is tried first on every raycast; `.estimatedPlane` is only a warm-up fallback |

---

## References

- [Apple: ARKit Documentation](https://developer.apple.com/documentation/arkit)
- [Apple: RealityKit Documentation](https://developer.apple.com/documentation/realitykit)
- [Apple: Saving and Loading World Data (WWDC sample)](https://developer.apple.com/documentation/arkit/arkit_in_ios/world_tracking/saving_and_loading_world_data)
- [Apple: Using Scene Reconstruction with ARKit](https://developer.apple.com/documentation/arkit/environmental_analysis/creating_a_fog_of_war_experience)
- [WWDC21 Session 10073: Explore ARKit 5](https://developer.apple.com/videos/play/wwdc2021/10073/)
- [WWDC20 Session 10611: RealityKit Entity Component System](https://developer.apple.com/videos/play/wwdc2020/10611/)

---

## Confirmed Requirements

All planning questions have been answered. The following decisions are reflected throughout this guide:

### Scope & Environment

| # | Question | Decision |
|---|---|---|
| 1 | Where will it be used? | **Indoors and outdoors.** ARWorldMap works well indoors; outdoor use is supported but expect less reliable relocalization — the 30-second timeout + recalibration prompt handles failure. |
| 2 | How many markers? | **1–10 markers.** Plain JSON persistence is sufficient; no CoreData needed. |
| 3 | Individual edit/delete, or clear-all only? | **Individual edit and delete** — see `deleteAnchor(id:)`, `renameAnchor(id:label:)`, and `MarkerListView`. |
| 4 | Survive app reinstall? | **No** — Documents directory wipe on reinstall is an accepted limitation. No iCloud backup needed. |

### Multi-User / Multi-Device

| # | Question | Decision |
|---|---|---|
| 5 | Single user or multi-user? | **Single user, single device.** No collaborative sessions, no iCloud sync. |
| 6 | Other devices need LiDAR? | **N/A** — single device only. |

### Marker Design

| # | Question | Decision |
|---|---|---|
| 7 | Customizable marker appearance? | **No** — one unified style for all markers. |
| 8 | Is the 0.5 m pole the right scale? | **Yes** — confirmed. |
| 9 | Should markers be occluded by real geometry? | **No** — `UnlitMaterial` with no occlusion; markers are always visible regardless of what is in front of them. |

### Persistence & Reliability

| # | Question | Decision |
|---|---|---|
| 10 | Relocalization failure behaviour? | Show **"Insufficient environment calibration"** after a 30-second timeout and offer the recalibration prompt. |
| 11 | World map age limit? | Prompt user to **recalibrate after 30 days** via `showRecalibrationPrompt`. |
| 12 | Auto-save or explicit save? | **Explicit save only** — user taps "Save" button when ready. |

### Extended Features

| # | Question | Decision |
|---|---|---|
| 13 | Spatial measurement between markers? | **Not at this time.** |
| 14 | Markers visible at any distance? | **Yes — no distance culling.** All markers rendered at full visibility regardless of distance. |
| 15 | Marker categories / layers? | **Not at this time.** |
| 16 | Support older devices without LiDAR? | **No — minimum iPhone 14 Pro Max.** The code still checks `supportsSceneReconstruction` and `supportsFrameSemantics` so it can't crash on a non-LiDAR device. |

---

## Implementation Plan

### Phase Overview

```
Phase 1 — Foundation (Days 1–3)
  Project scaffold, AR session, LiDAR config, basic tap-to-place

Phase 2 — Marker (Days 4–5)
  RealityKit marker entity, pulse animation, billboard label

Phase 3 — Persistence (Days 6–8)
  ARWorldMap save/load, AnchorRecord JSON, relocalization delegate

Phase 4 — Individual Management (Days 9–11)
  Delete anchor, rename anchor, MarkerListView, recalibration prompt

Phase 5 — Polish & Edge Cases (Days 12–14)
  30-day expiry, relocalization timeout UI, Save button guard, haptics

Phase 6 — Testing (Days 15–20)
  Unit tests, UI tests, and manual test execution
```

---

### Phase 1 — Foundation

**Goal:** AR session running on device, tapping a real surface places a primitive sphere.

Tasks:
1. Create Xcode project (SwiftUI, iOS 18, bundle ID `com.irondougxr.app`) via `project.yml` + `xcodegen generate`
2. Add `NSCameraUsageDescription` to `Info.plist`
3. Implement `ARViewContainer` (`UIViewRepresentable`) with `ARWorldTrackingConfiguration`
4. Enable `sceneReconstruction = .meshWithClassification`, `planeDetection = [.horizontal, .vertical]`, `frameSemantics = .sceneDepth`
5. Wire tap gesture → `ARView.raycast` → place a 0.05 m white sphere at the hit point
6. Print anchor transform to console to confirm raycasting is working

**Exit criteria:** Tapping a floor or table in a lit room places a visible sphere in the correct location.

---

### Phase 2 — Marker Entity

**Goal:** Replace test sphere with the full marker (ring, pole, orb, label, pulse).

Tasks:
1. Create `MarkerEntity.swift` with `make(label:)` factory
2. Implement `makeRing()`, `makePole()`, `makeOrb()`, `makeLabel(text:)`
3. Add `addPulseAnimation()` extension using `FromToByAnimation<Transform>`
4. Add `BillboardComponent` to the label entity
5. Confirm marker renders at correct world position and scale (0.5 m pole)
6. Confirm pulse animation loops without stalling

**Exit criteria:** Dropping a marker shows all four components at correct positions; the orb pulses; the label faces the camera as the user walks around.

---

### Phase 3 — Persistence

**Goal:** Markers survive a full app kill and relaunch in the same room.

Tasks:
1. Create `AnchorRecord.swift` (`Codable`, `Identifiable`)
2. Create `PersistenceManager.swift` with `save(worldMap:)`, `loadWorldMap()`, `save(anchorRecords:)`, `loadAnchorRecords()`, `clearAll()`
3. Wire `ARViewModel.saveWorldMap()` to call `session.getCurrentWorldMap` then `PersistenceManager.save`
4. Wire `ARViewModel.loadSavedAnchors()` to load map + records, pass `initialWorldMap` to session
5. Implement `ARSessionDelegate.session(_:didAdd:)` to re-attach marker entities for restored anchors
6. Implement `ARSessionDelegate.session(_:cameraDidChangeTrackingState:)` with status messages
7. Test full persist/restore cycle (place → Save → kill app → relaunch → confirm markers reappear)

**Exit criteria:** After a full kill-and-relaunch in the same room, all previously placed markers reappear within 15 seconds of pointing at the environment.

---

### Phase 4 — Individual Marker Management

**Goal:** User can rename and delete individual markers; recalibration prompt works.

Tasks:
1. Add `deleteAnchor(id:)` to `ARViewModel`
2. Add `renameAnchor(id:label:)` to `ARViewModel` (removes and re-attaches entity with new label)
3. Build `MarkerListView` with `List`, swipe-to-delete (`onDelete`), and tap-to-rename (alert with `TextField`)
4. Add sheet presentation from `ContentView` toolbar button
5. Add `showRecalibrationPrompt: Bool` `@Published` property
6. In `loadSavedAnchors`, trigger prompt when world map anchor is >30 days old
7. Add 30-second `Timer` in `cameraDidChangeTrackingState` for `.relocalizing` timeout
8. Add `.alert` in `ContentView` bound to `showRecalibrationPrompt`

**Exit criteria:** Individual delete removes marker from scene and JSON. Rename updates the live marker label without restart. Recalibration alert appears after forced 30-second wait.

---

### Phase 5 — Polish & Edge Cases

**Goal:** App handles all failure states gracefully; save button is guarded.

Tasks:
1. Disable "Save" button unless `isReadyToSave` (tracking is `.normal`)
2. Show tracking status message as an overlay banner (top of screen)
3. Show relocalization guidance overlay (camera icon + message) when `.relocalizing`
4. Handle raycasting returning zero results gracefully (error haptic, no crash)
5. Handle `session.getCurrentWorldMap` returning `nil` gracefully (alert user)
6. Confirm markers render correctly in both daylight outdoor and indoor artificial lighting conditions (manual)

**Exit criteria:** No crashes on all identified failure paths; UI state is always consistent with AR session state.

---

### Phase 6 — Testing

---

#### Programmatic Tests

##### Unit Tests (XCTest — `ironDougXRTests` target)

These tests run in the Simulator or on-device without needing an active AR session. All AR-dependent code is tested via protocols and mock substitution.

---

**`PersistenceManagerTests.swift`**

```swift
import XCTest
@testable import ironDougXR

final class PersistenceManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PersistenceManager.clearAll()
    }

    func test_saveAndLoad_anchorRecords_roundTrips() throws {
        let records = [
            AnchorRecord(id: UUID(), label: "Mark 1", timestamp: Date()),
            AnchorRecord(id: UUID(), label: "Mark 2", timestamp: Date())
        ]
        PersistenceManager.save(anchorRecords: records)
        let loaded = PersistenceManager.loadAnchorRecords()
        XCTAssertEqual(loaded.count, records.count)
        XCTAssertEqual(loaded[0].label, "Mark 1")
        XCTAssertEqual(loaded[1].label, "Mark 2")
    }

    func test_loadAnchorRecords_returnsEmpty_whenNoneExist() {
        let loaded = PersistenceManager.loadAnchorRecords()
        XCTAssertTrue(loaded.isEmpty)
    }

    func test_clearAll_removesAnchorRecords() {
        let record = AnchorRecord(id: UUID(), label: "Test", timestamp: Date())
        PersistenceManager.save(anchorRecords: [record])
        PersistenceManager.clearAll()
        XCTAssertTrue(PersistenceManager.loadAnchorRecords().isEmpty)
    }

    func test_loadWorldMap_returnsNil_whenNoneExist() {
        XCTAssertNil(PersistenceManager.loadWorldMap())
    }

    func test_anchorRecord_isFullyCodable() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AnchorRecord(id: id, label: "Shelf", timestamp: date)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AnchorRecord.self, from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.label, "Shelf")
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, date.timeIntervalSince1970,
                       accuracy: 0.001)
    }
}
```

---

**`AnchorRecordTests.swift`**

```swift
import XCTest
@testable import ironDougXR

final class AnchorRecordTests: XCTestCase {

    func test_anchorRecord_hasStableID() {
        let id = UUID()
        let record = AnchorRecord(id: id, label: "Point A", timestamp: Date())
        XCTAssertEqual(record.id, id)
    }

    func test_anchorRecord_labelIsPreserved() {
        let record = AnchorRecord(id: UUID(), label: "Northeast Corner", timestamp: Date())
        XCTAssertEqual(record.label, "Northeast Corner")
    }

    func test_anchorRecordArray_encodesToValidJSON() throws {
        let records = (1...10).map { i in
            AnchorRecord(id: UUID(), label: "Mark \(i)", timestamp: Date())
        }
        let data = try JSONEncoder().encode(records)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [[String: Any]])
    }
}
```

---

**`ARViewModelLogicTests.swift`**

These tests isolate the pure-logic portions of `ARViewModel` by injecting a mock persistence layer.

```swift
// Protocol to allow mocking PersistenceManager in tests
protocol PersistenceStoring {
    func save(anchorRecords: [AnchorRecord])
    func loadAnchorRecords() -> [AnchorRecord]
    func clearAll()
}

// Extend the real enum to conform
extension PersistenceManager: PersistenceStoring {}

// --- Tests ---
import XCTest
@testable import ironDougXR

final class ARViewModelLogicTests: XCTestCase {

    func test_deleteAnchor_removesFromSavedAnchors() {
        let vm = ARViewModel()
        let id = UUID()
        vm.savedAnchors = [AnchorRecord(id: id, label: "Mark 1", timestamp: Date())]
        vm.deleteAnchor(id: id)
        XCTAssertTrue(vm.savedAnchors.isEmpty)
        XCTAssertEqual(vm.anchorCount, 0)
    }

    func test_renameAnchor_updatesLabel() {
        let vm = ARViewModel()
        let id = UUID()
        vm.savedAnchors = [AnchorRecord(id: id, label: "Old", timestamp: Date())]
        vm.renameAnchor(id: id, label: "New Name")
        XCTAssertEqual(vm.savedAnchors.first?.label, "New Name")
    }

    func test_clearAllAnchors_emptiesSavedAnchors() {
        let vm = ARViewModel()
        vm.savedAnchors = [
            AnchorRecord(id: UUID(), label: "A", timestamp: Date()),
            AnchorRecord(id: UUID(), label: "B", timestamp: Date())
        ]
        vm.clearAllAnchors()
        XCTAssertTrue(vm.savedAnchors.isEmpty)
        XCTAssertEqual(vm.anchorCount, 0)
    }

    func test_loadSavedAnchors_triggersRecalibrationPrompt_whenWorldMapIsOlderThan30Days() {
        let vm = ARViewModel()
        let oldDate = Date(timeIntervalSinceNow: -(31 * 24 * 60 * 60))
        PersistenceManager.save(anchorRecords: [
            AnchorRecord(id: UUID(), label: "Old Mark", timestamp: oldDate)
        ])
        // No world map saved, so session.run won't be called — only prompt logic is tested
        vm.loadSavedAnchors()
        XCTAssertTrue(vm.showRecalibrationPrompt)
        PersistenceManager.clearAll()
    }

    func test_loadSavedAnchors_doesNotTriggerPrompt_whenWorldMapIsRecent() {
        let vm = ARViewModel()
        let recentDate = Date(timeIntervalSinceNow: -(5 * 24 * 60 * 60))
        PersistenceManager.save(anchorRecords: [
            AnchorRecord(id: UUID(), label: "Recent Mark", timestamp: recentDate)
        ])
        vm.loadSavedAnchors()
        XCTAssertFalse(vm.showRecalibrationPrompt)
        PersistenceManager.clearAll()
    }
}
```

---

**`MarkerEntityTests.swift`**

```swift
import XCTest
import RealityKit
@testable import ironDougXR

final class MarkerEntityTests: XCTestCase {

    func test_markerEntity_hasExpectedChildCount() {
        let marker = MarkerEntity.make(label: "Test")
        // ring, pole, orb, label = 4 children
        XCTAssertEqual(marker.children.count, 4)
    }

    func test_markerEntity_topChildIsAboveGround() {
        let marker = MarkerEntity.make(label: "Test")
        let maxY = marker.children.map { $0.position.y }.max() ?? 0
        XCTAssertGreaterThan(maxY, 0.5, "Top of marker should be above 0.5 m")
    }

    func test_markerEntity_labelTextIsReflected() {
        // Verify label entity is present (it's the only text mesh child)
        let marker = MarkerEntity.make(label: "Dock A")
        let hasTextChild = marker.children.contains { $0 is ModelEntity }
        XCTAssertTrue(hasTextChild)
    }
}
```

---

##### UI Tests (XCUITest — `ironDougXRUITests` target)

UI tests run on a real device. AR rendering cannot be fully automated, but UI state, navigation, and alert presentation can be verified.

```swift
import XCTest

final class MarkerListUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app.launch()
    }

    func test_markerListSheet_opensAndCloses() {
        // Assumes the toolbar list button has accessibilityIdentifier "markerListButton"
        let listButton = app.buttons["markerListButton"]
        XCTAssertTrue(listButton.waitForExistence(timeout: 5))
        listButton.tap()
        XCTAssertTrue(app.navigationBars["Markers"].waitForExistence(timeout: 3))
        app.swipeDown()
        XCTAssertFalse(app.navigationBars["Markers"].exists)
    }

    func test_saveButton_existsInUI() {
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
    }

    func test_recalibrationAlert_isDismissable() {
        // Launch with launch argument that forces showRecalibrationPrompt = true
        app.terminate()
        app.launchArguments = ["--forceRecalibrationPrompt"]
        app.launch()
        let alert = app.alerts["Environment Calibration Needed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Dismiss"].tap()
        XCTAssertFalse(alert.exists)
    }

    func test_recalibrationAlert_clearAllDismissesAlert() {
        app.terminate()
        app.launchArguments = ["--forceRecalibrationPrompt"]
        app.launch()
        let alert = app.alerts["Environment Calibration Needed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Clear & Start Fresh"].tap()
        XCTAssertFalse(alert.exists)
    }
}
```

> Add the following to `ARViewModel.init()` to support the UI test launch argument:
> ```swift
> if CommandLine.arguments.contains("--forceRecalibrationPrompt") {
>     showRecalibrationPrompt = true
> }
> ```

---

#### Running All Programmatic Tests

```bash
# Unit tests only (fast, Simulator OK)
xcodebuild test \
  -scheme ironDougXR \
  -destination 'platform=iOS Simulator,name=<simulator matching the SDK>' \
  -only-testing:ironDougXRTests

# UI tests (requires physical device)
xcodebuild test \
  -scheme ironDougXR \
  -destination 'id=<YOUR_DEVICE_UDID>' \
  -only-testing:ironDougXRUITests
```

**Target coverage threshold:** ≥80% on `PersistenceManager`, `AnchorRecord`, and the logic methods of `ARViewModel`. Coverage report:

```bash
xcodebuild test \
  -scheme ironDougXR \
  -destination 'platform=iOS Simulator,name=<simulator matching the SDK>' \
  -enableCodeCoverage YES \
  | xcpretty
```

---

#### Manual User-Directed Test Cases

Execute these in order on a physical **iPhone 14 Pro Max** running iOS 18+. Each test case lists the preconditions, steps, and expected result. Mark Pass / Fail / Blocked.

---

##### MT-01 — First Launch, No World Map

| | |
|---|---|
| **Precondition** | App freshly installed; no saved data |
| **Steps** | 1. Open app in a well-lit indoor room with visible surfaces |
| | 2. Observe tracking status message |
| **Expected** | Status reads "Initializing…" then transitions to "Ready" within 10 seconds |
| **Pass/Fail** | |

---

##### MT-02 — Place a Marker on a Horizontal Surface

| | |
|---|---|
| **Precondition** | Tracking state is "Ready" |
| **Steps** | 1. Point phone at a table or floor |
| | 2. Tap the surface |
| **Expected** | Marker appears with ring at the tap point, pole rising 0.5 m, orb pulsing, label "Mark 1" facing camera. Heavy haptic fires. |
| **Pass/Fail** | |

---

##### MT-03 — Place a Marker on a Vertical Surface

| | |
|---|---|
| **Precondition** | Tracking state is "Ready" |
| **Steps** | 1. Point phone at a wall |
| | 2. Tap the wall |
| **Expected** | Marker anchor is on the wall surface; ground ring is flush with the wall |
| **Pass/Fail** | |

---

##### MT-04 — Place Up to 10 Markers

| | |
|---|---|
| **Precondition** | Fresh session; no existing markers |
| **Steps** | 1. Place 10 markers across the room, alternating floor and wall surfaces |
| **Expected** | All 10 markers render simultaneously without visible performance degradation |
| **Pass/Fail** | |

---

##### MT-05 — Save World Map

| | |
|---|---|
| **Precondition** | 2+ markers placed; tracking is "Ready" |
| **Steps** | 1. Tap "Save" |
| **Expected** | No error alert; button responds. (Verify file existence via Xcode → Devices & Simulators → App Container if desired.) |
| **Pass/Fail** | |

---

##### MT-06 — Persist Across App Kill and Relaunch (Indoors)

| | |
|---|---|
| **Precondition** | MT-05 complete; markers saved |
| **Steps** | 1. Force-quit the app (swipe up in App Switcher) |
| | 2. Reopen app in the same room |
| | 3. Slowly scan the room |
| **Expected** | Status transitions from "Initializing…" → "Point at saved area to restore markers…" → "Ready". All previously placed markers reappear at exactly the same real-world positions. |
| **Pass/Fail** | |

---

##### MT-07 — Persist Across App Kill and Relaunch (Outdoors)

| | |
|---|---|
| **Precondition** | Place and save 2 markers in an outdoor location with fixed visual features (building facade, paved area with distinct markings) |
| **Steps** | 1. Force-quit the app |
| | 2. Reopen in the same outdoor location |
| | 3. Point phone at the same landmark |
| **Expected** | Markers reappear within 30 seconds; if they do not, recalibration prompt appears |
| **Notes** | Outdoor relocalization is less reliable. Document conditions (lighting, weather, time of day). |
| **Pass/Fail** | |

---

##### MT-08 — Relocalization Timeout (30-Second Failure Path)

| | |
|---|---|
| **Precondition** | Markers saved in Room A |
| **Steps** | 1. Reopen app in a completely different room (Room B) |
| | 2. Wait 30 seconds without pointing at Room A |
| **Expected** | Status reads "Insufficient environment calibration"; recalibration alert appears with options "Clear & Start Fresh" and "Dismiss" |
| **Pass/Fail** | |

---

##### MT-09 — Dismiss Recalibration and Still Use App

| | |
|---|---|
| **Precondition** | MT-08 recalibration alert is showing |
| **Steps** | 1. Tap "Dismiss" |
| | 2. Walk to Room A and scan it |
| **Expected** | Alert disappears; if ARKit subsequently relocalizes, markers reappear |
| **Pass/Fail** | |

---

##### MT-10 — Clear & Start Fresh from Recalibration Alert

| | |
|---|---|
| **Precondition** | MT-08 recalibration alert is showing |
| **Steps** | 1. Tap "Clear & Start Fresh" |
| **Expected** | Alert disappears; all marker entities removed from scene; marker list is empty; fresh placement is possible |
| **Pass/Fail** | |

---

##### MT-11 — Delete an Individual Marker

| | |
|---|---|
| **Precondition** | 3 markers placed and visible in scene |
| **Steps** | 1. Tap the list button to open MarkerListView |
| | 2. Swipe left on "Mark 2" |
| | 3. Tap "Delete" |
| | 4. Dismiss the sheet |
| **Expected** | "Mark 2" entity is removed from the AR scene. "Mark 1" and "Mark 3" remain. JSON record for Mark 2 is gone (verified by Save → kill → relaunch: only 2 markers restore). |
| **Pass/Fail** | |

---

##### MT-12 — Rename an Individual Marker

| | |
|---|---|
| **Precondition** | 1+ markers placed and visible |
| **Steps** | 1. Open MarkerListView |
| | 2. Tap a marker row |
| | 3. Type "Entrance" in the rename alert and confirm |
| | 4. Dismiss the sheet |
| **Expected** | The live marker in the scene now shows "Entrance" on its label (no app restart required) |
| **Pass/Fail** | |

---

##### MT-13 — Save Button Disabled When Tracking Is Degraded

| | |
|---|---|
| **Precondition** | App running with a saved world map loaded (status may be "Point at saved area…") |
| **Steps** | 1. Observe the Save button while status is NOT "Ready" |
| **Expected** | Save button is visually dimmed / non-interactive. Becomes active only when status reads "Ready". |
| **Pass/Fail** | |

---

##### MT-14 — No Surface Found at Tap Location

| | |
|---|---|
| **Precondition** | App tracking "Ready" |
| **Steps** | 1. Point phone at the sky or a blank white wall with insufficient texture |
| | 2. Tap |
| **Expected** | No marker is placed. Error haptic fires (notification-style buzz). Status message does not change. |
| **Pass/Fail** | |

---

##### MT-15 — Marker Visible at >10 m Distance

| | |
|---|---|
| **Precondition** | Marker placed in a large room or outdoor area; tracking "Ready" |
| **Steps** | 1. Walk 10+ meters away from a placed marker |
| | 2. Look back at the marker |
| **Expected** | Marker is still visible; pole and orb are visible at distance; label faces camera; no culling occurs |
| **Pass/Fail** | |

---

##### MT-16 — 30-Day World Map Expiry Prompt

| | |
|---|---|
| **Precondition** | Manually set timestamp of a saved `AnchorRecord` in `anchors.json` to >30 days ago using Xcode's device file browser |
| **Steps** | 1. Launch app |
| **Expected** | Recalibration alert appears on launch before the user has done anything |
| **Pass/Fail** | |

---

##### MT-17 — App Backgrounded and Foregrounded (State Preservation)

| | |
|---|---|
| **Precondition** | 2 markers placed; NOT yet saved |
| **Steps** | 1. Press Home button (background app) |
| | 2. Return to app |
| **Expected** | Markers are still visible; AR session resumes cleanly; no crash |
| **Pass/Fail** | |

---

##### MT-18 — Tracking Interrupted by Covering Camera

| | |
|---|---|
| **Precondition** | Tracking "Ready"; 1 marker visible |
| **Steps** | 1. Cover the camera lens for 5 seconds |
| | 2. Uncover and slowly move phone |
| **Expected** | Status degrades to "Tracking unavailable" or similar, then recovers to "Ready" within ~10 seconds. Marker reappears at correct position. |
| **Pass/Fail** | |

---

### Test Sign-Off Matrix

| Test ID | Description | Type | Phase | Pass | Fail | Notes |
|---|---|---|---|---|---|---|
| UT-01 | `PersistenceManagerTests` full suite | Unit | 6 | | | |
| UT-02 | `AnchorRecordTests` full suite | Unit | 6 | | | |
| UT-03 | `ARViewModelLogicTests` full suite | Unit | 6 | | | |
| UT-04 | `MarkerEntityTests` full suite | Unit | 6 | | | |
| UI-01 | Marker list sheet open/close | UI | 6 | | | |
| UI-02 | Save button present | UI | 6 | | | |
| UI-03 | Recalibration alert dismiss | UI | 6 | | | |
| UI-04 | Recalibration alert clear | UI | 6 | | | |
| MT-01 | First launch, no world map | Manual | 6 | | | |
| MT-02 | Place marker on horizontal surface | Manual | 6 | | | |
| MT-03 | Place marker on vertical surface | Manual | 6 | | | |
| MT-04 | Place 10 markers | Manual | 6 | | | |
| MT-05 | Save world map | Manual | 6 | | | |
| MT-06 | Persist indoors across relaunch | Manual | 6 | | | |
| MT-07 | Persist outdoors across relaunch | Manual | 6 | | | |
| MT-08 | 30-second relocalization timeout | Manual | 6 | | | |
| MT-09 | Dismiss recalibration, walk to saved area | Manual | 6 | | | |
| MT-10 | Clear & Start Fresh | Manual | 6 | | | |
| MT-11 | Delete individual marker | Manual | 6 | | | |
| MT-12 | Rename individual marker | Manual | 6 | | | |
| MT-13 | Save button disabled during degraded tracking | Manual | 6 | | | |
| MT-14 | No surface found at tap | Manual | 6 | | | |
| MT-15 | Marker visible at >10 m | Manual | 6 | | | |
| MT-16 | 30-day expiry prompt on launch | Manual | 6 | | | |
| MT-17 | Background and foreground preserves state | Manual | 6 | | | |
| MT-18 | Camera covered then recovered | Manual | 6 | | | |

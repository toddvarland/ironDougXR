# Key Learnings — ironDougXR

Lessons captured while building a native iOS AR app with persistent anchors using ARKit 6, RealityKit 2, and Swift 6.

---

## 1. Simulator Compatibility

### ARKit does not run in the iOS Simulator
`ARView(cameraMode: .ar, ...)` crashes immediately on any simulator with `SIGABRT`. The app must guard against this:

```swift
func makeUIView(context: Context) -> ARView {
    #if targetEnvironment(simulator)
    return ARView(frame: .zero)   // placeholder — no AR in sim
    #else
    let arView = ARView(frame: .zero, cameraMode: .ar,
                        automaticallyConfigureSession: false)
    // ... setup
    return arView
    #endif
}
```

Without this guard, the test host app crashes before XCTest can even connect, producing the misleading error: *"Test crashed with signal abrt before establishing connection."*

### SDK vs. Runtime mismatch kills the app silently
Compiling with the iOS 26.2 SDK (Xcode 26.3) and running on an iOS 18.5 simulator produces a `dyld` symbol-not-found crash:

```
Symbol not found: _$s10RealityKit12AnchorEntityC6anchorACSo8ARAncho...
Expected in: RealityKit.framework
```

The rule: **always run tests on a simulator whose runtime version matches the SDK**. Check with:
```bash
xcrun simctl list runtimes
xcrun simctl list devices available
```

### Parallel testing on simulator clones can hang
With Xcode 27.1, `xcodebuild test` with `parallelizable: true` ran tests on "Clone N of …" simulators and never exited. The same tests pass in about a second when run serially. The unit tests also share the app's Documents files, so they shouldn't run in parallel anyway. `project.yml` now sets `parallelizable: false`; on the command line, add `-parallel-testing-enabled NO -test-timeouts-enabled YES` so a stuck test fails instead of hanging.

A beta-build simulator runtime (e.g. iOS 27.1 `24A94425` vs SDK `24A94232`) also stalled at test launch. Prefer a released runtime. Killing `xcodebuild` mid-run can leave the simulator wedged; shut it down and boot it again before the next run.

---

## 2. xcodegen Scheme Configuration

### The auto-generated scheme has no test targets
When `project.yml` has no `schemes:` block, xcodegen creates a single scheme with only the app target in the build phase. Running `xcodebuild test -only-testing:ironDougXRTests` silently does nothing (no tests run, no error).

**Fix:** Always add an explicit `schemes:` block:

```yaml
schemes:
  ironDougXR:
    build:
      targets:
        ironDougXR: all
        ironDougXRTests: [test]
        ironDougXRUITests: [test]
    test:
      config: Debug
      targets:
        - name: ironDougXRTests
        - name: ironDougXRUITests
```

### Conflicting deployment target settings
`project.yml` had a global `settings.base.IPHONEOS_DEPLOYMENT_TARGET: 16.0` that conflicted with the per-target `deploymentTarget: "18.0"`. Always set deployment target only at the target level, or make sure the target-level setting wins.

---

## 3. RealityKit API Availability

### Several APIs require iOS 18+
Even though RealityKit itself is available earlier, these specific APIs need iOS 18:

| API | Minimum |
|---|---|
| `MeshResource.generateCylinder` | iOS 18.0 |
| `BillboardComponent` (without `#available`) | iOS 18.0 |
| `ContentUnavailableView` | iOS 17.0 |

Setting the deployment target to iOS 18 eliminates the need for scattered `#available` checks throughout the codebase.

### `AnimationResource.repeat(sequence:)` is broken
The multi-step sequence API (`AnimationResource.sequence` + `AnimationResource.repeat`) does not work reliably. Use a single `FromToByAnimation<Transform>` with `repeatMode: .autoReverse` instead:

```swift
let anim = FromToByAnimation<Transform>(
    name: "pulse",
    from: base,
    to: expanded,
    duration: 0.75,
    timing: .easeInOut,
    bindTarget: .transform,
    repeatMode: .autoReverse   // loops grow→shrink→grow automatically
)
```

---

## 4. Swift 6 Strict Concurrency

### `@MainActor` + `ARSessionDelegate` pattern
`ARSessionDelegate` methods are called on a background queue. With `SWIFT_STRICT_CONCURRENCY: complete`, you cannot call `@MainActor` methods from these delegates directly. The correct pattern:

```swift
// ARViewModel is @MainActor
nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
    Task { @MainActor [weak self] in
        self?.handleFrameUpdate(frame)
    }
}
```

Mark delegate conformance methods `nonisolated` and always dispatch back to the main actor via `Task { @MainActor in ... }`.

### `@preconcurrency import` for older SDKs
ARKit types like `ARWorldMap` predate Swift concurrency and aren't marked `Sendable`. Import with `@preconcurrency` to suppress false-positive warnings:

```swift
@preconcurrency import ARKit
```

### UI test property isolation
In Swift 6, stored properties in `XCTestCase` that are `@MainActor`-isolated cannot be initialized inline as `let`. Use `var` with `setUp()`:

```swift
// ❌ Fails under Swift 6 strict concurrency
let app = XCUIApplication()

// ✅ Correct
var app: XCUIApplication!
override func setUp() {
    super.setUp()
    app = XCUIApplication()
}
```

---

## 5. ARKit Persistence

### Two separate files are needed
`ARWorldMap` (the spatial fingerprint) and the app's anchor metadata (`[AnchorRecord]`) are stored separately:

- `worldmap.arexperience` — `NSKeyedArchiver` / `NSKeyedUnarchiver`
- `anchors.json` — `JSONEncoder` / `JSONDecoder`

`ARWorldMap` is not `Codable`, so it cannot go in the same JSON file.

### Keep the two files in agreement
`anchors.json` must only list markers whose `ARAnchor` is inside the saved world map. Writing a record on every tap breaks this: if the user quits without saving, the record survives but its anchor never comes back, so the marker shows in the list but never in the scene.

- New markers stay in memory until `getCurrentWorldMap` succeeds and the map is on disk
- On save, commit only the anchor IDs actually present in the captured map (a tap can land while the save is in flight)
- On launch, drop any record whose ID isn't in the loaded map's anchors
- Measure map age from the map file's modification date, not from marker timestamps — re-saving should reset the clock

### Always check `supportsSceneReconstruction` and `supportsFrameSemantics`
LiDAR features will crash on non-LiDAR devices if enabled unconditionally:

```swift
if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
    config.sceneReconstruction = .meshWithClassification
}
```

The iPhone 14 Pro Max guarantees LiDAR, but defensive checks make the code portable.

### World map age matters for UX
ARKit relocalization can fail silently if the saved world map is too old (environment changed). Prompting the user to recalibrate after 30 days, and timing out relocalization after 30 seconds with a clear message, prevents users from getting stuck in a confused `isRelocalizing` state.

---

## 6. RealityKit Entity Hierarchy

### Marker entity structure that works
A readable, accurate AR marker with a 4-child hierarchy:

```
root (Entity)
├── ring    (cylinder, h=0.005m, r=0.12m, y=0.0025)   — floor indicator
├── pole    (cylinder, h=0.50m,  r=0.007m, y=0.25)    — vertical staff
├── orb     (sphere,   r=0.045m,           y=0.52)    — pulsing beacon
└── label   (text mesh, BillboardComponent, y=0.60)   — always faces camera
```

`UnlitMaterial` is essential — `SimpleMaterial` makes markers dark in shadowed AR environments.

`BillboardComponent` on the label entity makes it face the camera without any manual transform updates.

---

## 7. Testing AR Without Hardware

Unit tests can cover all business logic without a real device:

- **`PersistenceManager`** — pure file I/O, fully testable in simulator
- **`AnchorRecord`** — `Codable` struct, fully testable
- **`ARViewModel` logic** — delete/rename/clearAll/expiry checks are `@MainActor` but have no ARKit dependencies; instantiate and call directly in `@MainActor` test methods
- **`MarkerEntity`** — RealityKit mesh generation works in the iOS 26.2 simulator (no GPU required for mesh allocation)

UI tests can verify existence of controls, sheet navigation, and alert flows because SwiftUI renders even without a real camera feed (the AR view just shows a blank/static frame in the simulator).

**What still needs a real device:** raycasting, anchor placement, world map save/load with actual spatial data, relocalization, and LiDAR mesh visualization.

---

## 8. Build Tooling

### Anything set in the Xcode UI is lost on regenerate
`DEVELOPMENT_TEAM` had been set in Xcode's Signing pane, so `xcodegen generate` silently dropped it and device builds failed to sign. Put every build setting you rely on in `project.yml`.

### Use `xcodegen generate` after every `project.yml` change
The `.xcodeproj` is generated, not hand-edited. Changes to `project.yml` won't take effect until you regenerate:

```bash
xcodegen generate
```

Keep `project.yml` as the source of truth; don't edit `project.pbxproj` directly.

### Useful build / test commands

```bash
# Build for simulator (no signing needed)
xcodebuild build \
  -scheme ironDougXR \
  -project ironDougXR.xcodeproj \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  CODE_SIGNING_ALLOWED=NO

# Unit tests only
xcodebuild test \
  -scheme ironDougXR \
  -project ironDougXR.xcodeproj \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:ironDougXRTests \
  CODE_SIGNING_ALLOWED=NO

# Find iOS 26.2 simulator UDIDs
xcrun simctl list devices available | grep "iOS 26"
```

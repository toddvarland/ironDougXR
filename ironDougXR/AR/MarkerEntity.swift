import RealityKit
import UIKit

@MainActor
enum MarkerEntity {

    static func make(label: String) -> Entity {
        let root = Entity()
        root.addChild(makeRing())
        root.addChild(makePole())
        let orb = makeOrb()
        addPulseAnimation(to: orb)
        root.addChild(orb)
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

    private static func makeLabel(text: String) -> Entity {
        let font = UIFont.boldSystemFont(ofSize: 0.055)
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.004,
            font: font,
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let mat = UnlitMaterial(color: .white)
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        let bounds = entity.visualBounds(relativeTo: nil)
        entity.position = SIMD3<Float>(-bounds.extents.x / 2, 0.60, 0)
        entity.components.set(BillboardComponent())
        return entity
    }

    // MARK: - Pulse Animation

    private static func addPulseAnimation(to entity: ModelEntity) {
        let base = entity.transform
        var expanded = base
        expanded.scale = SIMD3<Float>(repeating: 1.35)
        do {
            // repeatMode: .autoReverse loops grow→shrink→grow continuously
            let pulseAnim = FromToByAnimation<Transform>(
                name: "pulse",
                from: base,
                to: expanded,
                duration: 0.75,
                timing: .easeInOut,
                bindTarget: .transform,
                repeatMode: .autoReverse
            )
            let resource = try AnimationResource.generate(with: pulseAnim)
            entity.playAnimation(resource)
        } catch {
            // Pulse unavailable on this SDK version — orb is still visible
        }
    }
}

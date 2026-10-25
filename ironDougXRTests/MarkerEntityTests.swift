import XCTest
import RealityKit
@testable import ironDougXR

@MainActor
final class MarkerEntityTests: XCTestCase {

    func test_markerEntity_hasFourChildren() {
        let marker = MarkerEntity.make(label: "Test")
        // ring, pole, orb, label = 4 children
        XCTAssertEqual(marker.children.count, 4)
    }

    func test_markerEntity_topComponentIsAboveHalfMeter() {
        let marker = MarkerEntity.make(label: "Test")
        let maxY = marker.children.map { $0.position.y }.max() ?? 0
        XCTAssertGreaterThan(maxY, 0.5, "Tallest child should be positioned above 0.5 m")
    }

    func test_poleIsEightFeetTall() throws {
        let marker = MarkerEntity.make(label: "Test")
        let pole = try XCTUnwrap(marker.children[1] as? ModelEntity)
        let height = pole.visualBounds(relativeTo: marker).extents.y
        XCTAssertEqual(height, 2.4384, accuracy: 0.01)
        XCTAssertEqual(pole.position.y, 2.4384 / 2, accuracy: 0.001, "Pole should stand on the ground")
    }

    func test_orbAndLabelSitAbovePole() {
        let marker = MarkerEntity.make(label: "Test")
        let ys = marker.children.map { $0.position.y }
        // children: ring, pole, orb, label
        XCTAssertGreaterThan(ys[2], MarkerEntity.poleHeight)
        XCTAssertGreaterThan(ys[3], ys[2])
    }

    func test_markerEntity_ringIsNearGround() {
        let marker = MarkerEntity.make(label: "Test")
        let minY = marker.children.map { $0.position.y }.min() ?? 1
        XCTAssertLessThan(minY, 0.05, "Ground ring should be within 5 cm of origin")
    }

    func test_markerEntity_allChildrenAreModelEntities() {
        let marker = MarkerEntity.make(label: "Test")
        let allAreModels = marker.children.allSatisfy { $0 is ModelEntity }
        XCTAssertTrue(allAreModels)
    }

    func test_markerEntity_differentLabelsProduceDifferentEntities() {
        let marker1 = MarkerEntity.make(label: "Alpha")
        let marker2 = MarkerEntity.make(label: "Beta")
        // Both should be valid, distinct entity instances
        XCTAssertFalse(marker1 === marker2)
    }

    func test_markerEntity_emptyLabelDoesNotCrash() {
        let marker = MarkerEntity.make(label: "")
        XCTAssertNotNil(marker)
    }

    func test_markerEntity_longLabelDoesNotCrash() {
        let longLabel = String(repeating: "A", count: 100)
        let marker = MarkerEntity.make(label: longLabel)
        XCTAssertNotNil(marker)
    }
}

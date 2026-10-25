import XCTest
import Combine
@testable import ironDougXR

@MainActor
final class ARViewModelLogicTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PersistenceManager.clearAll()
    }

    override func tearDown() {
        PersistenceManager.clearAll()
        super.tearDown()
    }

    func test_deleteAnchor_removesFromSavedAnchors() {
        let vm = ARViewModel()
        let id = UUID()
        vm.savedAnchors = [AnchorRecord(id: id, label: "Mark 1", timestamp: Date())]
        vm.deleteAnchor(id: id)
        XCTAssertTrue(vm.savedAnchors.isEmpty)
        XCTAssertEqual(vm.anchorCount, 0)
    }

    func test_deleteAnchor_onlyRemovesTargetRecord() {
        let vm = ARViewModel()
        let id1 = UUID()
        let id2 = UUID()
        vm.savedAnchors = [
            AnchorRecord(id: id1, label: "Mark 1", timestamp: Date()),
            AnchorRecord(id: id2, label: "Mark 2", timestamp: Date())
        ]
        vm.deleteAnchor(id: id1)
        XCTAssertEqual(vm.savedAnchors.count, 1)
        XCTAssertEqual(vm.savedAnchors[0].id, id2)
    }

    func test_renameAnchor_updatesLabel() {
        let vm = ARViewModel()
        let id = UUID()
        vm.savedAnchors = [AnchorRecord(id: id, label: "Old", timestamp: Date())]
        vm.renameAnchor(id: id, label: "New Name")
        XCTAssertEqual(vm.savedAnchors.first?.label, "New Name")
    }

    func test_renameAnchor_preservesTimestamp() throws {
        let vm = ARViewModel()
        let id = UUID()
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        vm.savedAnchors = [AnchorRecord(id: id, label: "Old", timestamp: originalDate)]
        vm.renameAnchor(id: id, label: "New")
        let renamedTimestamp = try XCTUnwrap(vm.savedAnchors.first?.timestamp.timeIntervalSince1970)
        XCTAssertEqual(
            renamedTimestamp,
            originalDate.timeIntervalSince1970,
            accuracy: 0.001
        )
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

    func test_clearAllAnchors_deletesPersistedRecords() {
        let vm = ARViewModel()
        vm.savedAnchors = [AnchorRecord(id: UUID(), label: "X", timestamp: Date())]
        PersistenceManager.save(anchorRecords: vm.savedAnchors)
        vm.clearAllAnchors()
        XCTAssertTrue(PersistenceManager.loadAnchorRecords().isEmpty)
    }

    // MARK: - World map expiry

    func test_needsRecalibration_falseWithoutWorldMap() {
        XCTAssertFalse(ARViewModel.needsRecalibration(mapSavedAt: nil))
    }

    func test_needsRecalibration_atBoundaryDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60
        XCTAssertFalse(ARViewModel.needsRecalibration(mapSavedAt: now - 29 * day, now: now))
        XCTAssertFalse(ARViewModel.needsRecalibration(mapSavedAt: now - 30 * day, now: now))
        XCTAssertTrue(ARViewModel.needsRecalibration(mapSavedAt: now - 31 * day, now: now))
    }

    func test_needsRecalibration_ignoresMarkerAge() {
        // A fresh Save resets the clock even when markers were placed long ago
        let now = Date()
        XCTAssertFalse(ARViewModel.needsRecalibration(mapSavedAt: now - 60, now: now))
    }

    func test_worldMapSavedAt_isNilWhenNoneSaved() {
        XCTAssertNil(PersistenceManager.worldMapSavedAt())
    }

    func test_startSession_withoutWorldMap_doesNotPromptRecalibration() {
        PersistenceManager.save(anchorRecords: [
            AnchorRecord(id: UUID(), label: "Old", timestamp: Date(timeIntervalSinceNow: -(60 * 24 * 60 * 60)))
        ])
        let vm = ARViewModel()
        vm.startSession()
        XCTAssertFalse(vm.showRecalibrationPrompt)
    }

    // MARK: - Default labels

    func test_nextDefaultLabel_startsAtOne() {
        XCTAssertEqual(ARViewModel.nextDefaultLabel(after: []), "Mark 1")
    }

    func test_nextDefaultLabel_countsUpPastGaps() {
        let records = [
            AnchorRecord(id: UUID(), label: "Mark 1", timestamp: Date()),
            AnchorRecord(id: UUID(), label: "Mark 3", timestamp: Date())
        ]
        XCTAssertEqual(ARViewModel.nextDefaultLabel(after: records), "Mark 4")
    }

    func test_nextDefaultLabel_ignoresRenamedMarkers() {
        let records = [
            AnchorRecord(id: UUID(), label: "Mark 2", timestamp: Date()),
            AnchorRecord(id: UUID(), label: "Front Door", timestamp: Date()),
            AnchorRecord(id: UUID(), label: "Mark ten", timestamp: Date())
        ]
        XCTAssertEqual(ARViewModel.nextDefaultLabel(after: records), "Mark 3")
    }

    // MARK: - New markers persist only on Save

    func test_addUnsavedRecord_isNotWrittenToDisk() {
        let vm = ARViewModel()
        vm.addUnsavedRecord(id: UUID())
        XCTAssertEqual(vm.savedAnchors.count, 1)
        XCTAssertTrue(vm.hasUnsavedChanges)
        XCTAssertTrue(PersistenceManager.loadAnchorRecords().isEmpty)
    }

    func test_renameOfSavedMarker_doesNotWriteUnsavedOnes() {
        let vm = ARViewModel()
        let savedID = UUID()
        vm.savedAnchors = [AnchorRecord(id: savedID, label: "Mark 1", timestamp: Date())]
        vm.addUnsavedRecord(id: UUID())
        vm.renameAnchor(id: savedID, label: "Desk")
        let onDisk = PersistenceManager.loadAnchorRecords()
        XCTAssertEqual(onDisk.map(\.id), [savedID])
        XCTAssertEqual(onDisk.first?.label, "Desk")
    }

    func test_commitUnsavedRecords_writesOnlyAnchorsInMap() {
        let vm = ARViewModel()
        let inMap = UUID()
        let placedDuringSave = UUID()
        vm.addUnsavedRecord(id: inMap)
        vm.addUnsavedRecord(id: placedDuringSave)
        vm.commitUnsavedRecords(inMap: [inMap])
        XCTAssertEqual(PersistenceManager.loadAnchorRecords().map(\.id), [inMap])
        XCTAssertEqual(vm.unsavedIDs, [placedDuringSave])
        XCTAssertEqual(vm.savedAnchors.count, 2)
    }

    func test_deleteUnsavedMarker_clearsUnsavedFlag() {
        let vm = ARViewModel()
        let id = UUID()
        vm.addUnsavedRecord(id: id)
        vm.deleteAnchor(id: id)
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func test_records_dropsThoseNotInWorldMap() {
        let kept = AnchorRecord(id: UUID(), label: "Kept", timestamp: Date())
        let orphan = AnchorRecord(id: UUID(), label: "Orphan", timestamp: Date())
        XCTAssertEqual(
            ARViewModel.records([kept, orphan], restorableFrom: [kept.id]).map(\.id),
            [kept.id]
        )
        XCTAssertTrue(ARViewModel.records([kept], restorableFrom: []).isEmpty)
    }

    func test_startSession_withoutWorldMap_dropsOrphanedRecords() {
        PersistenceManager.save(anchorRecords: [
            AnchorRecord(id: UUID(), label: "Never saved", timestamp: Date())
        ])
        let vm = ARViewModel()
        vm.startSession()
        XCTAssertTrue(vm.savedAnchors.isEmpty)
        XCTAssertTrue(PersistenceManager.loadAnchorRecords().isEmpty)
    }

    // MARK: - Count stays in sync with the list

    func test_anchorCount_tracksSavedAnchors() {
        let vm = ARViewModel()
        let id = UUID()
        vm.savedAnchors = [
            AnchorRecord(id: id, label: "Mark 1", timestamp: Date()),
            AnchorRecord(id: UUID(), label: "Mark 2", timestamp: Date())
        ]
        XCTAssertEqual(vm.anchorCount, 2)
        vm.deleteAnchor(id: id)
        XCTAssertEqual(vm.anchorCount, 1)
        vm.clearAllAnchors()
        XCTAssertEqual(vm.anchorCount, 0)
    }

    func test_renameAnchor_publishesChange() {
        let vm = ARViewModel()
        let id = UUID()
        vm.savedAnchors = [AnchorRecord(id: id, label: "Old", timestamp: Date())]
        var changes = 0
        let sub = vm.objectWillChange.sink { changes += 1 }
        vm.renameAnchor(id: id, label: "New")
        sub.cancel()
        XCTAssertGreaterThan(changes, 0, "List must redraw on rename even with no live entity")
    }
}

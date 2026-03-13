import XCTest
@testable import ironDougXR

final class PersistenceManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PersistenceManager.clearAll()
    }

    override func tearDown() {
        PersistenceManager.clearAll()
        super.tearDown()
    }

    func test_saveAndLoad_anchorRecords_roundTrips() throws {
        let records = [
            AnchorRecord(id: UUID(), label: "Mark 1", timestamp: Date()),
            AnchorRecord(id: UUID(), label: "Mark 2", timestamp: Date())
        ]
        PersistenceManager.save(anchorRecords: records)
        let loaded = PersistenceManager.loadAnchorRecords()
        XCTAssertEqual(loaded.count, 2)
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

    func test_saveAnchorRecords_overwritesPrevious() {
        let first = [AnchorRecord(id: UUID(), label: "Original", timestamp: Date())]
        PersistenceManager.save(anchorRecords: first)
        let second = [
            AnchorRecord(id: UUID(), label: "Updated A", timestamp: Date()),
            AnchorRecord(id: UUID(), label: "Updated B", timestamp: Date())
        ]
        PersistenceManager.save(anchorRecords: second)
        let loaded = PersistenceManager.loadAnchorRecords()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].label, "Updated A")
    }

    func test_saveEmptyArray_writesAndLoadsEmpty() {
        PersistenceManager.save(anchorRecords: [AnchorRecord(id: UUID(), label: "X", timestamp: Date())])
        PersistenceManager.save(anchorRecords: [])
        let loaded = PersistenceManager.loadAnchorRecords()
        XCTAssertTrue(loaded.isEmpty)
    }
}

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

    func test_anchorRecord_timestampIsPreserved() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AnchorRecord(id: UUID(), label: "X", timestamp: date)
        XCTAssertEqual(record.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_anchorRecord_roundTripsViaCodable() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AnchorRecord(id: id, label: "Shelf", timestamp: date)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AnchorRecord.self, from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.label, "Shelf")
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_anchorRecordArray_encodesToValidJSONArray() throws {
        let records = (1...10).map { i in
            AnchorRecord(id: UUID(), label: "Mark \(i)", timestamp: Date())
        }
        let data = try JSONEncoder().encode(records)
        let json = try JSONSerialization.jsonObject(with: data)
        let array = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertEqual(array.count, 10)
    }

    func test_anchorRecord_labelIsMutable() {
        var record = AnchorRecord(id: UUID(), label: "Old", timestamp: Date())
        record.label = "New"
        XCTAssertEqual(record.label, "New")
    }
}

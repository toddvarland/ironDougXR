import Foundation
@preconcurrency import ARKit

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

    // MARK: - World Map

    static func save(worldMap: ARWorldMap) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: worldMap,
            requiringSecureCoding: true
        )
        try data.write(to: worldMapURL, options: .atomic)
    }

    /// When the world map was last written; every Save refreshes it.
    static func worldMapSavedAt() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: worldMapURL.path)
        return attributes?[.modificationDate] as? Date
    }

    static func loadWorldMap() -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    // MARK: - Anchor Records

    static func save(anchorRecords: [AnchorRecord]) {
        do {
            let data = try JSONEncoder().encode(anchorRecords)
            try data.write(to: anchorRecordsURL, options: .atomic)
        } catch {
            print("PersistenceManager: failed to save anchor records — \(error)")
        }
    }

    static func loadAnchorRecords() -> [AnchorRecord] {
        guard
            let data = try? Data(contentsOf: anchorRecordsURL),
            let records = try? JSONDecoder().decode([AnchorRecord].self, from: data)
        else { return [] }
        return records
    }

    // MARK: - Clear

    static func clearAll() {
        try? FileManager.default.removeItem(at: worldMapURL)
        try? FileManager.default.removeItem(at: anchorRecordsURL)
    }
}

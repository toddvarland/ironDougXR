import Foundation

struct AnchorRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var label: String
    let timestamp: Date
}

// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Models/CustomWord.swift @ bbae9e0e
// Changes: dropped the GRDB import and FetchableRecord/PersistableRecord conformance; ChirpText has
// no database dependency, persistence is ChirpStore's job.

import Foundation

public struct CustomWord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var word: String
    public var replacement: String?
    public var source: Source
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public enum Source: String, Codable, Sendable {
        case manual
        case learned
    }

    public init(
        id: UUID = UUID(),
        word: String,
        replacement: String? = nil,
        source: Source = .manual,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.word = word
        self.replacement = replacement
        self.source = source
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

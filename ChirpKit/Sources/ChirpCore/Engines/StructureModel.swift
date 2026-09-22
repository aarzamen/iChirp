// M6 contract; no conformers in M1.

/// JSON extracted by a `StructureModel`, with the model's confidence in 0...1.
public struct StructuredOutput: Sendable, Equatable {
    public var json: String
    public var confidence: Double

    public init(json: String, confidence: Double) {
        self.json = json
        self.confidence = confidence
    }
}

/// A structured-extraction and embedding engine plug-in.
public protocol StructureModel: Sendable {
    var descriptor: EngineDescriptor { get }
    func extract(jsonSchema: String, from text: String, privacyClass: PrivacyClass) async throws -> StructuredOutput
    func embed(_ text: String) async throws -> [Float]
}

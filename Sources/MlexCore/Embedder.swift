import Foundation
import NaturalLanguage

/// On-device sentence embeddings from Apple's NaturalLanguage framework (512 dimensions,
/// about 2.5 ms per sentence). Used for memory retrieval and duplicate detection.
public actor Embedder {
    public static let shared = Embedder()
    private var model: NLEmbedding?
    private var loaded = false

    public func vector(for text: String) -> [Float]? {
        if !loaded { loaded = true; model = NLEmbedding.sentenceEmbedding(for: .english) }
        guard let model, let v = model.vector(for: String(text.prefix(500))) else { return nil }
        return v.map { Float($0) }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na.squareRoot() * nb.squareRoot())
        return d > 0 ? dot / d : 0
    }
}

import Foundation

/// Semantic image tool (src/genos/tools/images.ts, spec §11.5).
public struct ImgQuery: Sendable, Equatable {
    public var q: String
    public var seed: Int
    public var w: Int
    public var h: Int

    public init(q: String, seed: Int, w: Int, h: Int) {
        self.q = q
        self.seed = seed
        self.w = w
        self.h = h
    }
}

public enum Images {
    /// clamp with JS NaN semantics: a non-number falls to the min bound.
    private static func clamp(_ n: Int?, _ min: Int, _ max: Int) -> Int {
        guard let n else { return min }
        return Swift.max(min, Swift.min(max, n))
    }

    /// Parse an /api/img?... reference; nil for any other src.
    /// Key-only pairs (no "=") are SKIPPED entirely - unlike parseGenosUrl.
    /// q defaults to "abstract gradient", +→space, stripped to [a-zA-Z0-9, -],
    /// trimmed. seed default 1 clamp [1,10000]; w default 800 clamp [40,1600];
    /// h default 500 clamp [40,1600]; NaN → the min bound.
    public static func parseImgUrl(_ src: String) -> ImgQuery? {
        guard src.hasPrefix("/api/img") else { return nil }
        var params: [String: String] = [:]
        let query = src.components(separatedBy: "?").count > 1 ? src.components(separatedBy: "?")[1] : ""
        for pair in query.components(separatedBy: "&") {
            guard let eq = pair.range(of: "=") else { continue }
            let key = String(pair[..<eq.lowerBound])
            let value = String(pair[eq.upperBound...])
            params[key] = jsDecodeURIComponent(value) ?? value
        }
        var q = params["q"] ?? ""
        if q.isEmpty { q = "abstract gradient" }
        q = q.replacingOccurrences(of: "+", with: " ")
        q = JSRegex.replacingAll("[^a-zA-Z0-9, -]", in: q, with: "")
        q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let seedText = params["seed"].flatMap { $0.isEmpty ? nil : $0 } ?? "1"
        let wText = params["w"].flatMap { $0.isEmpty ? nil : $0 } ?? "800"
        let hText = params["h"].flatMap { $0.isEmpty ? nil : $0 } ?? "500"
        return ImgQuery(
            q: q,
            seed: clamp(jsParseInt(seedText), 1, 10_000),
            w: clamp(jsParseInt(wText), 40, 1600),
            h: clamp(jsParseInt(hText), 40, 1600)
        )
    }

    /// https://loremflickr.com/{w}/{h}/{keywords}?lock={seed} where keywords
    /// is q with runs of spaces/commas collapsed to "," then percent-encoded.
    public static func loremflickrUrl(_ query: ImgQuery) -> String {
        let keywords = jsEncodeURIComponent(JSRegex.replacingAll("[ ,]+", in: query.q, with: ","))
        return "https://loremflickr.com/\(query.w)/\(query.h)/\(keywords)?lock=\(query.seed)"
    }

    /// Unsplash raw URL + crop suffix: pick candidates[seed % count] and
    /// append &w={w}&h={h}&fit=crop&q=80. Empty candidates → LoremFlickr.
    public static func resolveUnsplash(_ query: ImgQuery, candidates: [String]) -> String {
        guard !candidates.isEmpty else { return loremflickrUrl(query) }
        let raw = candidates[query.seed % candidates.count]
        return "\(raw)&w=\(query.w)&h=\(query.h)&fit=crop&q=80"
    }
}

/// query → Unsplash raw URLs, with in-flight dedupe. Empty array = search
/// failed, use LoremFlickr. Networking injected; Phase 3 wires a live client.
@MainActor
public final class UnsplashCache {
    private var cache: [String: [String]] = [:]

    public init() {}

    public func cached(_ q: String) -> [String]? {
        cache[q]
    }

    public func store(_ q: String, urls: [String]) {
        cache[q] = urls
    }
}

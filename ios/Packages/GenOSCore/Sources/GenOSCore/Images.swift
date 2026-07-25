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
    /// Parse an /api/img?... reference; nil for any other src.
    /// Key-only pairs (no "=") are SKIPPED entirely - unlike parseGenosUrl.
    /// q defaults to "abstract gradient", +→space, stripped to [a-zA-Z0-9, -],
    /// trimmed. seed default 1 clamp [1,10000]; w default 800 clamp [40,1600];
    /// h default 500 clamp [40,1600]; NaN → the min bound.
    public static func parseImgUrl(_ src: String) -> ImgQuery? {
        nil // STUB
    }

    /// https://loremflickr.com/{w}/{h}/{keywords}?lock={seed} where keywords
    /// is q with runs of spaces/commas collapsed to "," then percent-encoded.
    public static func loremflickrUrl(_ query: ImgQuery) -> String {
        "" // STUB
    }

    /// Unsplash raw URL + crop suffix: pick candidates[seed % count] and
    /// append &w={w}&h={h}&fit=crop&q=80. Empty candidates → LoremFlickr.
    public static func resolveUnsplash(_ query: ImgQuery, candidates: [String]) -> String {
        "" // STUB
    }
}

/// query → Unsplash raw URLs, with in-flight dedupe. Empty array = search
/// failed, use LoremFlickr. Networking injected; Phase 3 wires a live client.
@MainActor
public final class UnsplashCache {
    public init() {}

    public func cached(_ q: String) -> [String]? {
        nil // STUB
    }

    public func store(_ q: String, urls: [String]) {
        // STUB
    }
}

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
    /// clamp with JS Number semantics: NaN AND ±Infinity fall to the min
    /// bound (RN: `Number.isFinite(n) ? n : min` before Math.min/max), so a
    /// digit run long enough to overflow to Infinity clamps to min, while a
    /// merely huge finite value (e.g. a 23-digit seed ≈ 1.23e22) clamps to
    /// max - both matching JS parseInt feeding the clamp.
    private static func clamp(_ n: Double, _ min: Int, _ max: Int) -> Int {
        guard n.isFinite else { return min }
        return Int(Swift.max(Double(min), Swift.min(Double(max), n)))
    }

    /// Parse an /api/img?... reference; nil for any other src.
    /// Key-only pairs (no "=") are SKIPPED entirely - unlike parseGenosUrl.
    /// q defaults to "abstract gradient", +→space, stripped to [a-zA-Z0-9, -],
    /// trimmed. seed default 1 clamp [1,10000]; w default 800 clamp [40,1600];
    /// h default 500 clamp [40,1600]; NaN/±Infinity → the min bound.
    public static func parseImgUrl(_ src: String) -> ImgQuery? {
        // RN: src.startsWith / src.split("?") / pair.indexOf("=") - all
        // UTF-16-level. Scalar-level prefix + splits keep combining marks
        // glued onto "g", "?", "&" or "=" (model-controlled srcs) from
        // changing what parses.
        guard jsHasPrefix(src, "/api/img") else { return nil }
        var params: [String: String] = [:]
        let queryParts = jsSplit(src, on: "?")
        let query = queryParts.count > 1 ? queryParts[1] : ""
        for pair in jsSplit(query, on: "&") {
            guard let (key, value) = jsSplitFirst(pair, on: "=") else { continue }
            params[key] = jsDecodeURIComponent(value) ?? value
        }
        var q = params["q"] ?? ""
        if q.isEmpty { q = "abstract gradient" }
        // RN: .replace(/\+/g, " ") - regex (UTF-16); literal
        // replacingOccurrences would skip a "+" glued to a combining mark.
        q = JSRegex.replacingAll("\\+", in: q, with: " ")
        // RN: /[^a-zA-Z0-9, -]/g - explicit ASCII class + no `i` flag, so ICU
        // and JS semantics are identical (audited, no change needed).
        q = JSRegex.replacingAll("[^a-zA-Z0-9, -]", in: q, with: "")
        // RN: .trim() - exact ECMAScript whitespace set.
        q = jsTrim(q)
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
    /// RN: /[ ,]+/g - literal ASCII class, identical in ICU and JS (audited).
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

/// query → Unsplash raw URLs, with in-flight dedupe (images.ts
/// unsplashCache + unsplashPending). Empty array = search failed, use
/// LoremFlickr. Networking injected via HTTPFetching; Phase 3 wires a live
/// client.
@MainActor
public final class UnsplashCache {
    private var cache: [String: [String]] = [:]
    /// images.ts unsplashPending: one shared fetch per in-flight query.
    private var pending: [String: Task<Void, Never>] = [:]
    private let http: HTTPFetching
    private let accessKey: String?

    public init(http: HTTPFetching, accessKey: String?) {
        self.http = http
        self.accessKey = accessKey
    }

    public func cached(_ q: String) -> [String]? {
        cache[q]
    }

    public func store(_ q: String, urls: [String]) {
        cache[q] = urls
    }

    /// ensureUnsplash parity: concurrent ensures for the same query await one
    /// shared fetch (a pending entry is joined, never duplicated); the entry
    /// is removed on completion (RN `finally`), so a LATER ensure fetches
    /// again - callers consult cached() first, exactly like useSemanticImage.
    /// Any failure (HTTP error, thrown fetch, malformed JSON) caches [].
    public func ensure(_ q: String) async {
        if let inFlight = pending[q] {
            await inFlight.value
            return
        }
        // Task {} inherits MainActor isolation; pending[q] is set before any
        // suspension point, so a concurrent ensure always sees it.
        let task = Task { [weak self, http, accessKey] in
            let urls = await UnsplashCache.fetchCandidates(q, http: http, accessKey: accessKey)
            guard let self else { return }
            self.cache[q] = urls
            self.pending[q] = nil
        }
        pending[q] = task
        await task.value
    }

    /// GET https://api.unsplash.com/search/photos?query=...&per_page=10 with
    /// Client-ID auth; maps results[].urls.raw, dropping absent/empty (RN
    /// `.filter((u): u is string => !!u)`). Non-OK → {} → []; throw → [].
    private static func fetchCandidates(
        _ q: String,
        http: HTTPFetching,
        accessKey: String?
    ) async -> [String] {
        let request = HTTPRequest(
            url: "https://api.unsplash.com/search/photos?query=\(jsEncodeURIComponent(q))&per_page=10",
            method: "GET",
            headers: ["Authorization": "Client-ID \(accessKey ?? "")"]
        )
        guard
            let (head, data) = try? await http.fetch(request),
            head.ok,
            let json = JSONValue.parse(data)
        else { return [] }
        let results = json["results"]?.arrayValue ?? []
        return results.compactMap { r -> String? in
            guard let raw = r["urls"]?["raw"]?.stringValue, !raw.isEmpty else { return nil }
            return raw
        }
    }
}

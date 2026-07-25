//
//  SemanticImage.swift
//  AppLessCore
//
//  `useSemanticImage` (src/genos/tools/images.ts) without React: turn a
//  model-emitted `src` into a loadable URL.
//
//  The parsing and URL building already live in `GenOSCore.Images` (verified
//  against the TypeScript there); this file is only the resolution POLICY the
//  renderers apply, so `AppLessUI` never re-derives it.
//
//  NO SwiftUI in this file.
//

import Foundation
import GenOSCore

public enum SemanticImage {

    /// How a `src` resolved.
    public enum Resolution: Sendable, Equatable {
        /// Load this URL.
        case url(String)
        /// An Unsplash search is in flight - show the themed placeholder and
        /// nothing else, so the image never double-loads.
        case pending
        /// No `src` at all - show the placeholder.
        case none
    }

    /// Resolve without an Unsplash key: `/api/img?...` references become
    /// LoremFlickr URLs, everything else passes through untouched.
    /// `tools/images.ts` L84-113 with `UNSPLASH_ACCESS_KEY` unset.
    public static func resolve(_ src: String?) -> Resolution {
        guard let src, !src.isEmpty else { return .none }
        guard let query = Images.parseImgUrl(src) else { return .url(src) }
        return .url(Images.loremflickrUrl(query))
    }

    /// Resolve with an Unsplash key. `candidates` is the cache entry for the
    /// parsed query: `nil` means "still searching" (placeholder), empty means
    /// "search failed" (LoremFlickr). `tools/images.ts` L105-113.
    public static func resolve(_ src: String?, unsplashCandidates: [String]?) -> Resolution {
        guard let src, !src.isEmpty else { return .none }
        guard let query = Images.parseImgUrl(src) else { return .url(src) }
        guard let candidates = unsplashCandidates else { return .pending }
        if candidates.isEmpty { return .url(Images.loremflickrUrl(query)) }
        return .url(Images.resolveUnsplash(query, candidates: candidates))
    }

    /// The parsed query behind a semantic `src`, for callers that need to warm
    /// the Unsplash cache before rendering.
    public static func query(_ src: String?) -> ImgQuery? {
        guard let src, !src.isEmpty else { return nil }
        return Images.parseImgUrl(src)
    }
}

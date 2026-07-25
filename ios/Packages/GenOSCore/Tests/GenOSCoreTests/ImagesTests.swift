import Foundation
import Testing
@testable import GenOSCore

// spec/openui-lang.md §11.5, src/genos/tools/images.ts
@Suite struct ParseImgUrlTests {
    @Test func nonSemanticSrcPassesThroughAsNil() {
        #expect(Images.parseImgUrl("https://example.com/x.png") == nil)
        #expect(Images.parseImgUrl("/api/image?q=x") == nil)
    }

    @Test func bareReferenceGetsAllDefaults() {
        #expect(Images.parseImgUrl("/api/img") == ImgQuery(q: "abstract gradient", seed: 1, w: 800, h: 500))
    }

    @Test func fullQueryParsed() {
        #expect(
            Images.parseImgUrl("/api/img?q=sushi+platter&seed=3&w=800&h=440")
                == ImgQuery(q: "sushi platter", seed: 3, w: 800, h: 440)
        )
    }

    @Test func keyOnlyPairsAreSkippedEntirely() {
        // Unlike parseGenosUrl: "q" with no "=" is absent → default applies.
        #expect(
            Images.parseImgUrl("/api/img?q&seed=2")
                == ImgQuery(q: "abstract gradient", seed: 2, w: 800, h: 500)
        )
    }

    @Test func qSanitizedToSafeCharset() {
        // caf%C3%A9 "neon"! → é and punctuation stripped, then trimmed.
        #expect(Images.parseImgUrl("/api/img?q=caf%C3%A9%20%22neon%22!")?.q == "caf neon")
    }

    @Test func badPercentEscapeKeptRawThenSanitized() {
        #expect(Images.parseImgUrl("/api/img?q=100%zz")?.q == "100zz")
    }

    @Test func clampsAndNaNFallToMinBound() {
        let clamped = Images.parseImgUrl("/api/img?seed=99999&w=20&h=5000")
        #expect(clamped == ImgQuery(q: "abstract gradient", seed: 10_000, w: 40, h: 1600))
        let nan = Images.parseImgUrl("/api/img?seed=abc&w=abc&h=abc")
        #expect(nan == ImgQuery(q: "abstract gradient", seed: 1, w: 40, h: 40))
        #expect(Images.parseImgUrl("/api/img?seed=0")?.seed == 1)
    }

    @Test func nbspPrefixedSeedSkipsFullJsWhitespace() {
        // %C2%A0 decodes to NBSP; JS parseInt skips it (full StrWhiteSpace).
        // node: clamp(parseInt(decodeURIComponent("%C2%A05"), 10), 1, 10000) === 5
        // (the old ' \t\n\r'-only skip yielded NaN → 1).
        #expect(Images.parseImgUrl("/api/img?seed=%C2%A05")?.seed == 5)
    }

    @Test func overflowLengthSeedsSaturateThroughDoubleLikeJs() {
        // node: clamp(parseInt("12345678901234567890123", 10), 1, 10000) === 10000
        // (parseInt → ~1.23e22, clamps at max - the old Int overflow → nil → 1).
        #expect(Images.parseImgUrl("/api/img?seed=12345678901234567890123")?.seed == 10_000)
        // node: parseInt("9".repeat(400), 10) === Infinity → Number.isFinite
        // false → min bound 1.
        #expect(Images.parseImgUrl("/api/img?seed=" + String(repeating: "9", count: 400))?.seed == 1)
    }

    @Test func combiningMarksGluedToDelimitersParseLikeJs() {
        // U+0301 straight after "/api/img": JS startsWith (UTF-16) still
        // matches; Character-level hasPrefix saw "g\u{301}" and bailed to nil.
        #expect(Images.parseImgUrl("/api/img\u{301}?w=1600")?.w == 1600)
        // U+0301 straight after "=": JS indexOf("=") still splits; value
        // "\u{301}99" → parseInt NaN → min bound 40. Character-level
        // range(of: "=") missed the glued "=" and left w at its default 800.
        #expect(Images.parseImgUrl("/api/img?w=\u{301}99")?.w == 40)
    }
}

@Suite struct ImageResolutionTests {
    @Test func loremflickrUrlConstruction() {
        #expect(
            Images.loremflickrUrl(ImgQuery(q: "sushi platter", seed: 3, w: 800, h: 440))
                == "https://loremflickr.com/800/440/sushi%2Cplatter?lock=3"
        )
    }

    @Test func loremflickrCollapsesSpaceCommaRunsToSingleComma() {
        #expect(
            Images.loremflickrUrl(ImgQuery(q: "a,  b, ,c", seed: 1, w: 40, h: 40))
                == "https://loremflickr.com/40/40/a%2Cb%2Cc?lock=1"
        )
    }

    @Test func unsplashPickIsSeedIndexedWithCropSuffix() {
        let q = ImgQuery(q: "sushi", seed: 5, w: 640, h: 480)
        let candidates = ["https://u/one", "https://u/two", "https://u/three"]
        // 5 % 3 == 2 → third candidate.
        #expect(Images.resolveUnsplash(q, candidates: candidates) == "https://u/three&w=640&h=480&fit=crop&q=80")
    }

    @Test func emptyCandidatesFallBackToLoremflickr() {
        let q = ImgQuery(q: "sushi", seed: 5, w: 640, h: 480)
        #expect(Images.resolveUnsplash(q, candidates: []) == "https://loremflickr.com/640/480/sushi?lock=5")
    }
}

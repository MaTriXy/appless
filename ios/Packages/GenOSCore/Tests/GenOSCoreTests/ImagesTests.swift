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

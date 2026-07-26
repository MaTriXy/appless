import Foundation
import Testing

@testable import AppLessCore

/// The wordmark is the one design asset the shell draws itself. These tests
/// pin the path data against `src/genos/shell/applessLogo.ts` and exercise the
/// SVG reader that replaces `react-native-svg`.
@Suite struct WordmarkTests {

    // MARK: The asset

    @Test func thePathDataIsTheRNAssetVerbatim() throws {
        let source = try Repo.text("src/genos/shell/applessLogo.ts")
        guard let range = source.range(of: "d=\""),
            let end = source[range.upperBound...].firstIndex(of: "\"")
        else {
            throw TestError("no path `d` attribute in applessLogo.ts")
        }
        let d = String(source[range.upperBound..<end])
        #expect(d == AppLessWordmark.pathData)
        #expect(source.contains("viewBox=\"0 0 840 217\""))
    }

    @Test func theAssetParsesIntoDrawableGeometry() throws {
        let commands = try VectorPath.parse(AppLessWordmark.pathData)
        #expect(!commands.isEmpty)
        #expect(commands == AppLessWordmark.commands)
        if case .move = commands[0] {} else {
            Issue.record("a path must open with a moveto")
        }
        // The asset is one filled glyph run: closed subpaths, no strays.
        #expect(commands.contains(.closeSubpath))
    }

    @Test func theGeometryStaysInsideItsViewBox() throws {
        let bounds = try #require(VectorPath.controlBounds(AppLessWordmark.commands))
        #expect(bounds.minX >= 0)
        #expect(bounds.minY >= 0)
        #expect(bounds.maxX <= AppLessWordmark.viewBoxWidth)
        #expect(bounds.maxY <= AppLessWordmark.viewBoxHeight)
        // …and actually fills it, so a scale-to-fit is meaningful.
        #expect(bounds.maxX > AppLessWordmark.viewBoxWidth * 0.5)
        #expect(bounds.maxY > AppLessWordmark.viewBoxHeight * 0.5)
    }

    @Test func everyCoordinateIsFinite() {
        for command in AppLessWordmark.commands {
            switch command {
            case .move(let x, let y), .line(let x, let y):
                #expect(x.isFinite && y.isFinite)
            case .curve(let a, let b, let c, let d, let x, let y):
                #expect([a, b, c, d, x, y].allSatisfy { $0.isFinite })
            case .closeSubpath:
                break
            }
        }
    }

    // MARK: The reader

    @Test func absoluteCommandsAreReadInOrder() throws {
        let commands = try VectorPath.parse("M10 20 L30 40 H50 V60 C1 2 3 4 5 6 Z")
        #expect(
            commands == [
                .move(x: 10, y: 20),
                .line(x: 30, y: 40),
                .line(x: 50, y: 40),
                .line(x: 50, y: 60),
                .curve(c1x: 1, c1y: 2, c2x: 3, c2y: 4, x: 5, y: 6),
                .closeSubpath,
            ])
    }

    @Test func relativeCommandsResolveAgainstThePen() throws {
        let commands = try VectorPath.parse("m10 10 l5 5 h5 v-5 c1 1 2 2 3 3 z")
        #expect(
            commands == [
                .move(x: 10, y: 10),
                .line(x: 15, y: 15),
                .line(x: 20, y: 15),
                .line(x: 20, y: 10),
                .curve(c1x: 21, c1y: 11, c2x: 22, c2y: 12, x: 23, y: 13),
                .closeSubpath,
            ])
    }

    @Test func closeReturnsThePenToTheSubpathStart() throws {
        let commands = try VectorPath.parse("M10 10 L20 20 Z l5 5")
        #expect(commands.last == .line(x: 15, y: 15))
    }

    @Test func repeatedArgumentsRepeatTheCommandAndMovetoRepeatsAsLineto() throws {
        #expect(
            try VectorPath.parse("M1 1 2 2 3 3") == [
                .move(x: 1, y: 1), .line(x: 2, y: 2), .line(x: 3, y: 3),
            ])
        #expect(
            try VectorPath.parse("M0 0L1 1 2 2") == [
                .move(x: 0, y: 0), .line(x: 1, y: 1), .line(x: 2, y: 2),
            ])
    }

    @Test func separatorsMayBeCommasSignsOrSecondDecimalPoints() throws {
        #expect(try VectorPath.parse("M1,2") == [.move(x: 1, y: 2)])
        #expect(try VectorPath.parse("M10-5") == [.move(x: 10, y: -5)])
        #expect(try VectorPath.parse("M1.5.5") == [.move(x: 1.5, y: 0.5)])
        #expect(try VectorPath.parse("M1e2 2E-1") == [.move(x: 100, y: 0.2)])
        #expect(try VectorPath.parse("  \n M 1  2 \t") == [.move(x: 1, y: 2)])
        #expect(try VectorPath.parse("") == [])
    }

    @Test func malformedPathsAreReportedNotGuessed() {
        #expect(throws: VectorPathError.truncatedCommand("M")) {
            try VectorPath.parse("M10")
        }
        #expect(throws: VectorPathError.unsupportedCommand("A")) {
            try VectorPath.parse("M0 0 A1 1 0 0 1 2 2")
        }
        #expect(throws: VectorPathError.missingInitialCommand) {
            try VectorPath.parse("10 20")
        }
    }

    @Test func boundsCoverControlPointsAndAnEmptyPathHasNone() {
        #expect(VectorPath.controlBounds([]) == nil)
        #expect(VectorPath.controlBounds([.closeSubpath]) == nil)
        let bounds = VectorPath.controlBounds([
            .move(x: 0, y: 0),
            .curve(c1x: -5, c1y: 3, c2x: 2, c2y: 9, x: 4, y: 1),
        ])
        #expect(bounds?.minX == -5)
        #expect(bounds?.maxY == 9)
        #expect(bounds?.maxX == 4)
        #expect(bounds?.minY == 0)
    }
}

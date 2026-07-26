//
//  VectorPath.swift
//  AppLessCore
//
//  A tiny SVG path-data reader, so the AppLess wordmark can be drawn as real
//  vector geometry instead of shipping a bitmap or a text approximation.
//
//  RN renders `APPLESS_LOGO_XML` through `react-native-svg`'s `SvgXml`; SwiftUI
//  has no SVG reader, so the `d` attribute is parsed HERE (pure Swift, Linux
//  tested) and `AppLessUI` only replays the commands into a `Path`.
//
//  Scope is deliberately the subset the wordmark uses plus its relative twins:
//  M/m, L/l, H/h, V/v, C/c, Z/z. Quadratic, arc and smooth commands are
//  reported as unsupported rather than silently mis-drawn.
//
//  NO SwiftUI in this file.
//

import Foundation

/// One resolved, ABSOLUTE drawing command. Relative input commands are
/// converted while parsing, so a consumer never tracks the pen itself.
public enum VectorPathCommand: Sendable, Equatable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case curve(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double)
    case closeSubpath
}

public enum VectorPathError: Error, Equatable, CustomStringConvertible {
    /// A command letter outside the supported subset.
    case unsupportedCommand(Character)
    /// A command ran out of numbers.
    case truncatedCommand(Character)
    /// Numbers before any command letter.
    case missingInitialCommand
    case malformedNumber(String)

    public var description: String {
        switch self {
        case .unsupportedCommand(let c): return "unsupported path command '\(c)'"
        case .truncatedCommand(let c): return "truncated arguments for path command '\(c)'"
        case .missingInitialCommand: return "path data starts with a number, not a command"
        case .malformedNumber(let s): return "malformed number '\(s)' in path data"
        }
    }
}

public enum VectorPath {

    /// Parse an SVG `d` attribute into absolute commands.
    public static func parse(_ data: String) throws -> [VectorPathCommand] {
        var numbers = NumberScanner(data)
        var commands: [VectorPathCommand] = []
        /// Current pen position.
        var x: Double = 0
        var y: Double = 0
        /// Where the current subpath started (where `Z` returns to).
        var startX: Double = 0
        var startY: Double = 0
        var pending: Character? = nil

        while let token = numbers.nextToken() {
            let letter: Character
            switch token {
            case .command(let c):
                letter = c
            case .number:
                // An implicit repeat: "M x y x y" repeats as lineto, and every
                // other command repeats itself (SVG 1.1 §8.3.2).
                guard let previous = pending else { throw VectorPathError.missingInitialCommand }
                letter = (previous == "M") ? "L" : (previous == "m" ? "l" : previous)
            }

            switch letter {
            case "M", "m":
                guard let dx = try numbers.number(), let dy = try numbers.number() else {
                    throw VectorPathError.truncatedCommand(letter)
                }
                x = (letter == "m") ? x + dx : dx
                y = (letter == "m") ? y + dy : dy
                startX = x
                startY = y
                commands.append(.move(x: x, y: y))
            case "L", "l":
                guard let dx = try numbers.number(), let dy = try numbers.number() else {
                    throw VectorPathError.truncatedCommand(letter)
                }
                x = (letter == "l") ? x + dx : dx
                y = (letter == "l") ? y + dy : dy
                commands.append(.line(x: x, y: y))
            case "H", "h":
                guard let dx = try numbers.number() else {
                    throw VectorPathError.truncatedCommand(letter)
                }
                x = (letter == "h") ? x + dx : dx
                commands.append(.line(x: x, y: y))
            case "V", "v":
                guard let dy = try numbers.number() else {
                    throw VectorPathError.truncatedCommand(letter)
                }
                y = (letter == "v") ? y + dy : dy
                commands.append(.line(x: x, y: y))
            case "C", "c":
                guard let a = try numbers.number(), let b = try numbers.number(),
                    let c = try numbers.number(), let d = try numbers.number(),
                    let e = try numbers.number(), let f = try numbers.number()
                else {
                    throw VectorPathError.truncatedCommand(letter)
                }
                let relative = (letter == "c")
                let c1x = relative ? x + a : a
                let c1y = relative ? y + b : b
                let c2x = relative ? x + c : c
                let c2y = relative ? y + d : d
                let endX = relative ? x + e : e
                let endY = relative ? y + f : f
                commands.append(.curve(c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y, x: endX, y: endY))
                x = endX
                y = endY
            case "Z", "z":
                commands.append(.closeSubpath)
                x = startX
                y = startY
            default:
                throw VectorPathError.unsupportedCommand(letter)
            }
            pending = letter
        }
        return commands
    }

    /// The tight bounding box of a command list, using CONTROL points for
    /// curves (a conservative superset - enough to assert the wordmark stays
    /// inside its viewBox).
    public static func controlBounds(_ commands: [VectorPathCommand])
        -> (minX: Double, minY: Double, maxX: Double, maxY: Double)?
    {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        var seen = false
        func note(_ px: Double, _ py: Double) {
            seen = true
            minX = min(minX, px)
            minY = min(minY, py)
            maxX = max(maxX, px)
            maxY = max(maxY, py)
        }
        for command in commands {
            switch command {
            case .move(let px, let py), .line(let px, let py):
                note(px, py)
            case .curve(let c1x, let c1y, let c2x, let c2y, let px, let py):
                note(c1x, c1y)
                note(c2x, c2y)
                note(px, py)
            case .closeSubpath:
                break
            }
        }
        return seen ? (minX, minY, maxX, maxY) : nil
    }

    // MARK: - Scanning

    private enum Token {
        case command(Character)
        case number
    }

    /// Splits path data into command letters and numbers, honoring SVG's
    /// separator rules: whitespace, commas, and the implicit break before a
    /// sign or a second decimal point ("10-5" is two numbers, "1.5.5" too).
    private struct NumberScanner {
        private let scalars: [Character]
        private var index: Int = 0

        init(_ text: String) {
            scalars = Array(text)
        }

        private static func isSeparator(_ c: Character) -> Bool {
            c == " " || c == "," || c == "\n" || c == "\r" || c == "\t" || c == "\u{0C}"
        }

        private mutating func skipSeparators() {
            while index < scalars.count, Self.isSeparator(scalars[index]) { index += 1 }
        }

        /// Peek at what comes next. A command letter is consumed; a number is
        /// left in place for `number()` to read.
        mutating func nextToken() -> Token? {
            skipSeparators()
            guard index < scalars.count else { return nil }
            let c = scalars[index]
            if c.isLetter {
                index += 1
                return .command(c)
            }
            return .number
        }

        /// Read one number, or nil when the next token is a command letter or
        /// the data ended.
        mutating func number() throws -> Double? {
            skipSeparators()
            guard index < scalars.count else { return nil }
            if scalars[index].isLetter { return nil }

            let start = index
            var seenDot = false
            var seenDigit = false
            if scalars[index] == "+" || scalars[index] == "-" { index += 1 }
            while index < scalars.count {
                let c = scalars[index]
                if c.isNumber {
                    seenDigit = true
                    index += 1
                } else if c == "." && !seenDot {
                    seenDot = true
                    index += 1
                } else if (c == "e" || c == "E") && seenDigit {
                    // Exponent: consume it plus an optional sign.
                    var lookahead = index + 1
                    if lookahead < scalars.count,
                        scalars[lookahead] == "+" || scalars[lookahead] == "-"
                    {
                        lookahead += 1
                    }
                    guard lookahead < scalars.count, scalars[lookahead].isNumber else { break }
                    index = lookahead
                } else {
                    break
                }
            }
            let text = String(scalars[start..<index])
            guard seenDigit, let value = Double(text) else {
                throw VectorPathError.malformedNumber(text)
            }
            return value
        }
    }
}

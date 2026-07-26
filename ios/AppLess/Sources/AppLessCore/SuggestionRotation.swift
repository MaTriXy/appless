//
//  SuggestionRotation.swift
//  AppLessCore
//
//  The home screen's three rotating suggestion lines (HomeScreen.tsx).
//
//  Every 4s ONE row is swapped for the next suggestion in the catalog,
//  cycling through the rows in order. RN keeps `slots` in state and the two
//  cursors in refs, advanced OUTSIDE the state updater so a double-invoked
//  updater cannot skip a suggestion; the same split is expressed here by
//  keeping all three in one value type whose `advance()` is called once per
//  tick.
//
//  NO SwiftUI in this file.
//

import Foundation
import GenOSCore

public struct SuggestionRotation: Sendable, Equatable {

    /// RN `setInterval(…, 4000)`.
    public static let intervalSeconds: Double = 4
    /// RN's initial `useState<number[]>([0, 1, 2])`.
    public static let defaultSlotCount = 3

    /// Indices into the suggestion catalog, one per visible row.
    public private(set) var slots: [Int]
    /// RN `nextIdx` ref - the next catalog entry to show.
    public private(set) var nextIndex: Int
    /// RN `turn` ref - which row gets swapped next.
    public private(set) var turn: Int
    private let suggestionCount: Int

    public init(
        slotCount: Int = SuggestionRotation.defaultSlotCount,
        suggestionCount: Int = Apps.suggestions.count
    ) {
        let slots = max(0, slotCount)
        let total = max(1, suggestionCount)
        self.slots = (0..<slots).map { $0 % total }
        self.nextIndex = slots
        self.turn = 0
        self.suggestionCount = total
    }

    /// One 4-second tick: `slots[turn % slots.count] = nextIdx % SUGGESTIONS.length`.
    public mutating func advance() {
        guard !slots.isEmpty else { return }
        let row = turn % slots.count
        let index = nextIndex % suggestionCount
        nextIndex += 1
        turn += 1
        slots[row] = index
    }

    /// The suggestions currently on screen (RN `visible`).
    public func visible(in suggestions: [Suggestion] = Apps.suggestions) -> [Suggestion] {
        guard !suggestions.isEmpty else { return [] }
        return slots.map { suggestions[$0 % suggestions.count] }
    }
}

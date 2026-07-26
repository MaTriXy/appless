import Foundation
import GenOSCore
import Testing

@testable import AppLessCore

/// `SuggestionRotation` and `HomeTiles` against `src/genos/shell/HomeScreen.tsx`.
@Suite struct HomeShellTests {

    // MARK: - Suggestion rotation

    @Test func rotationStartsOnTheFirstThreeSuggestions() {
        let r = SuggestionRotation()
        #expect(r.slots == [0, 1, 2])
        #expect(r.visible().map(\.label) == ["Order dinner", "My spending", "Text Maya"])
        #expect(SuggestionRotation.intervalSeconds == 4)
    }

    @Test func eachTickSwapsExactlyOneRowInOrder() {
        var r = SuggestionRotation()
        r.advance()
        #expect(r.slots == [3, 1, 2])
        r.advance()
        #expect(r.slots == [3, 4, 2])
        r.advance()
        #expect(r.slots == [3, 4, 5])
        // Back to the first row.
        r.advance()
        #expect(r.slots == [6, 4, 5])
    }

    @Test func theCatalogCursorWrapsAround() {
        var r = SuggestionRotation()
        // 10 suggestions, cursor starts at 3: seven ticks reach the end.
        for _ in 0..<7 { r.advance() }
        #expect(r.nextIndex == 10)
        r.advance()
        // 10 % 10 == 0 - the cursor wraps, it does not stall.
        #expect(r.slots.contains(0))
        #expect(r.turn == 8)
    }

    @Test func rotationNeverIndexesOutOfRange() {
        var r = SuggestionRotation()
        for _ in 0..<200 {
            r.advance()
            #expect(r.visible().count == 3)
        }
    }

    @Test func suggestionsAreTheRNCatalog() {
        // The rotation is only meaningful against the shipped catalog.
        #expect(Apps.suggestions.count == 10)
        #expect(Apps.suggestions.first?.command == "order some dinner from a great place nearby")
    }

    // MARK: - Tile icons

    @Test func aKnownAppUsesItsEmojiIcon() {
        for app in Apps.all {
            let icon = HomeTiles.icon(name: app.name, emoji: app.emoji, appId: app.id)
            #expect(icon != HomeTiles.fallbackIcon, "\(app.id) fell through to Sparkle")
        }
    }

    @Test func emojiWinsOverKeywords() {
        // "settings" would hit the GearSix keyword too, but the emoji table
        // is consulted first - and here it says something different.
        #expect(HomeTiles.icon(name: "Settings", emoji: "💬", appId: "settings") == "ChatCircle")
    }

    @Test func summonedThreadsFallBackToKeywords() {
        #expect(
            HomeTiles.icon(name: "Coffee run", emoji: "✨", appId: "summon-coffee-run") == "Coffee")
        #expect(
            HomeTiles.icon(name: "find me a plumber", emoji: "✨", appId: "summon-find-me-a-plumber")
                == HomeTiles.fallbackIcon)
    }

    @Test func theIdIsPartOfTheKeywordHaystack() {
        // The display name may have been renamed by the model; the slug of the
        // original query still carries the intent.
        #expect(HomeTiles.icon(name: "Nomad", emoji: "✨", appId: "summon-weekend-in-goa")
            == "AirplaneTilt")
    }

    @Test func keywordOrderDecidesTies() {
        // "order coffee" hits both Coffee (row 1) and BowlFood ("order", row 2);
        // RN takes the first row.
        #expect(HomeTiles.icon(name: "order coffee", emoji: "✨", appId: "summon-order-coffee")
            == "Coffee")
    }

    @Test func keywordMatchingIsCaseInsensitive() {
        #expect(HomeTiles.icon(name: "MY WORKOUT", emoji: "✨", appId: "summon-x") == "Barbell")
    }

    @Test func everyTileIconResolvesToAnSFSymbol() {
        let icons = Set(HomeTiles.iconsByEmoji.values)
            .union(HomeTiles.iconsBySuggestionLabel.values)
            .union(HomeTiles.keywordIcons.map(\.icon))
            .union([HomeTiles.fallbackIcon])
        for icon in icons {
            #expect(
                IconMap.resolvePhosphor(icon).symbolName != nil,
                "\(icon) has no SF Symbol in spec/icon-map.md §5")
        }
    }

    @Test func everySuggestionHasItsOwnIcon() {
        for suggestion in Apps.suggestions {
            #expect(
                HomeTiles.iconsBySuggestionLabel[suggestion.label] != nil,
                "\(suggestion.label) has no icon")
        }
    }

    // MARK: - One-word tile labels

    @Test func oneWordNameDropsFillerWords() {
        #expect(HomeTiles.oneWordName("Trip Planner") == "Trip")
        #expect(HomeTiles.oneWordName("My Day") == "Day")
        #expect(HomeTiles.oneWordName("The New Notes") == "Notes")
        #expect(HomeTiles.oneWordName("your workouts") == "workouts")
        #expect(HomeTiles.oneWordName("Messages") == "Messages")
    }

    @Test func oneWordNameSurvivesAllFillerAndBlankNames() {
        // RN: meaningful[0] ?? words[0] ?? name.
        #expect(HomeTiles.oneWordName("My The A") == "My")
        #expect(HomeTiles.oneWordName("   ") == "")
    }

    @Test func oneWordNameCollapsesRunsOfWhitespace() {
        #expect(HomeTiles.oneWordName("  my \t\n  grocery list ") == "grocery")
    }

    // MARK: - Home grid source

    @Test func onlyMinimizedAppsGetAHomeIcon() {
        var s = ShellState()
        s.launch(app: Apps.find(id: "messages")!, screenId: "screen-1")
        // Running, but never sent home: the switcher shows it, the grid does not.
        #expect(s.runningApps.count == 1)
        #expect(s.homeApps.isEmpty)
        s.commitMinimize(appId: "messages")
        #expect(s.homeApps.map(\.id) == ["messages"])
    }
}

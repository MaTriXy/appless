//
//  RendererPresentation.swift
//  AppLessCore
//
//  The decisions that used to sit inside a SwiftUI `body`: which label a
//  control shows, which index is highlighted, whether a tap does anything,
//  what a read-out prints, how many items go on a row.
//
//  None of it is view construction, all of it is graded against
//  `src/genos/ui/cupertino/{components,forms}.tsx` and
//  `src/genos/ui/shared/*`, and every rule here has a Linux test that also
//  exercises the branch the implementation does NOT take.
//
//  NO SwiftUI in this file.
//

import Foundation
import OpenUILang

// MARK: - Wrapping

/// CSS `flex-wrap: wrap` over fixed-size rows, as `StatTiles` (2 per row),
/// `PhotoGrid` (3) and the chart legend (3) use it.
public enum FlexWrap {

    /// Index ranges, one per row: `[0..<2, 2..<4, 4..<5]` for 5 items at 2 per
    /// row. A short LAST row is kept short - the layouts that use this let its
    /// items grow, which is what `flexGrow: 1` on a `flexBasis` tile does.
    public static func rows(count: Int, perRow: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        guard perRow > 0 else { return [0..<count] }
        return stride(from: 0, to: count, by: perRow).map { $0..<Swift.min($0 + perRow, count) }
    }
}

// MARK: - ListItem

/// Everything `ListItem` decides. `components.tsx` L179-225.
public enum ListItemPresentation {

    /// `onTap` exists, so the row is pressable AND shows the chevron.
    /// RN derives both from the same `useTap` result (`disabled={!onTap}`,
    /// `{onTap && <chevron/>}`), which is why they can never disagree.
    /// `shared/actions.ts` L14: `if (!action) return undefined`.
    public static func isInteractive(action: ActionPlan?) -> Bool {
        GenosActions.isTappable(action: action)
    }

    /// A row tap dispatches with NO form name - `triggerAction(label ?? "",
    /// undefined, action)` (`shared/actions.ts` L18-19).
    public static let dispatchesWithFormName: String? = nil
}

// MARK: - Select

/// `Select`'s two different label fallbacks. `forms.tsx` L101-168.
public enum SelectPresentation {

    /// `items.find((it) => it.value === field.value)` - L108. A `nil`
    /// selection matches nothing (react-lang stores no value until the user
    /// picks or a `value` prop seeds one).
    public static func selected(
        in items: [StructuralProps.SelectItem],
        value: String?
    ) -> StructuralProps.SelectItem? {
        guard let value else { return nil }
        return items.first { $0.value == value }
    }

    /// `"Select…"` - the last-resort label, L124.
    public static let emptyLabel = "Select\u{2026}"

    /// `selected?.label ?? props.placeholder ?? "Select…"` (L124).
    ///
    /// - Important: the chain does NOT fall back to the item's `value`. An
    ///   item written `SelectItem("us")` with no label leaves the closed
    ///   control showing the placeholder even while it IS selected, which is
    ///   what RN does; the open list shows `"us"` for the same item.
    public static func triggerLabel(
        selected: StructuralProps.SelectItem?,
        placeholder: String?
    ) -> String {
        selected?.label ?? placeholder ?? emptyLabel
    }

    /// `true` when the trigger is showing a placeholder rather than a choice -
    /// `color: selected ? t.ink : t.ink3` (L123). Note this tests the ITEM,
    /// not the label: a selected-but-label-less item still uses primary ink.
    public static func triggerShowsSelection(_ selected: StructuralProps.SelectItem?) -> Bool {
        selected != nil
    }
}

// MARK: - Tabs

/// `Tabs`' index arithmetic. `components.tsx` L623-676.
public enum TabsPresentation {

    /// `items[Math.min(active, Math.max(items.length - 1, 0))]` (L629): a tab
    /// list that SHRANK mid-stream must not strand the selection out of range.
    /// Returns `nil` only for an empty list.
    public static func contentIndex(active: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return Swift.min(Swift.max(active, 0), count - 1)
    }

    /// `backgroundColor: i === active ? t.group : "transparent"` (L650).
    ///
    /// - Important: RN highlights the RAW `active`, not the clamped index. So
    ///   while a shrinking list is showing the last tab's CONTENT, no segment
    ///   is highlighted at all until the user taps one. Highlighting the
    ///   clamped index instead would be a nicer UI and a divergence.
    public static func isHighlighted(index: Int, active: Int) -> Bool {
        index == active
    }

    /// `it.props?.label ?? \`Tab ${i + 1}\`` (L666).
    ///
    /// `??` fires on `undefined` only, so an item declared with an EMPTY label
    /// renders an empty segment - it does not fall back to `"Tab 1"`.
    public static func title(label: String?, index: Int) -> String {
        label ?? "Tab \(index + 1)"
    }
}

// MARK: - Chips

/// `Chips` are live filters: no `action` prop is involved, the label becomes
/// the request. `components.tsx` L573-621.
public enum ChipsPresentation {

    /// `if (i === active) return;` (L589) - re-tapping the active chip is a
    /// no-op, because it would ask the model to re-render the screen it is
    /// already showing.
    public static func shouldDispatch(tapped: Int, active: Int) -> Bool {
        tapped != active
    }

    /// `triggerAction(msg, undefined, undefined)` (L593-597) - no form name,
    /// no plan.
    public static let dispatchesWithFormName: String? = nil
}

// MARK: - Bubbles

/// `Bubbles` geometry. `components.tsx` L529-570.
public enum BubblePresentation {

    /// The four corner radii, clockwise from the top-left. `me` bubbles clip
    /// their BOTTOM-RIGHT corner, everyone else's the bottom-left (L558-559).
    public static func corners(isMine: Bool)
        -> (topLeft: Double, topRight: Double, bottomRight: Double, bottomLeft: Double)
    {
        let big = CdsMetrics.Radius.bubble
        let tail = CdsMetrics.Radius.bubbleTail
        return (big, big, isMine ? tail : big, isMine ? big : tail)
    }

    /// `maxWidth: "78%"` of the thread (L552).
    ///
    /// Returns `nil` before the first layout pass has measured a width, so the
    /// bubble is laid out uncapped rather than at zero width - one frame of
    /// full-width text instead of an invisible message.
    public static func maxWidth(threadWidth: Double) -> Double? {
        guard threadWidth > 0 else { return nil }
        return threadWidth * CdsMetrics.Spacing.bubbleMaxWidthFraction
    }
}

// MARK: - Slider

/// `Slider`'s numeric rules. `forms.tsx` L171-213.
public enum SliderPresentation {

    /// The contract declares `min` / `max` required, but a model can omit or
    /// mistype them; RN then hands `undefined` to `@react-native-community/slider`,
    /// whose own defaults are 0 and 1, so those are the defaults here too.
    ///
    /// A degenerate range (`max <= min`) would trap a SwiftUI `Slider` on a
    /// single value, so the upper bound is pushed one unit past the lower.
    /// RN's slider tolerates the degenerate range instead; this is the one
    /// place the port deliberately differs, and the difference is invisible
    /// unless the model emits `max <= min`.
    public static func bounds(min: Double?, max: Double?) -> (lower: Double, upper: Double) {
        let lower = min ?? 0
        let declared = max ?? 1
        return (lower, declared > lower ? declared : lower + 1)
    }

    /// `{Math.round(current * 100) / 100}` interpolated into a `<Text>`
    /// (L208) - so the string is JS's, not `%g`'s.
    ///
    /// `String(format: "%g", …)` was the old spelling and cut the value to six
    /// significant digits: a read-out of `123456.7` printed `123457`, and
    /// `1234567.89` printed `1.23457e+06`.
    public static func readoutText(_ value: Double) -> String {
        JSNumber.string(GenosProps.sliderReadout(value))
    }
}

// MARK: - Buttons

/// `Buttons` direction. `forms.tsx` L270-281.
public enum ButtonsPresentation {

    /// `props.direction === "column"` - anything else, including a missing
    /// prop, lays the buttons out in a row.
    public static func isColumn(direction: String?) -> Bool { direction == "column" }
}

// MARK: - Text inputs

/// The seeding handshake every text-like field performs on appear -
/// `useFieldState` + `useSetDefaultValue` (`shared/forms.ts` L19-36).
public enum FieldSeeding {

    /// The value a `Slider` seeds into form state:
    /// `props.value ?? props.defaultValue ?? [props.min]` (`forms.tsx` L178).
    ///
    /// `??` is nullish-coalescing, so an explicit `null` value falls through
    /// to `defaultValue` while an empty ARRAY (`[]`) does not.
    public static func sliderSeed(
        value: PropValue?,
        defaultValue: PropValue?,
        min: Double
    ) -> PropValue {
        if let value, !value.isJSNullish { return value }
        if let defaultValue, !defaultValue.isJSNullish { return defaultValue }
        return .array([.number(min)])
    }

    /// `typeof field.value === "string" ? field.value : ""` (`forms.tsx` L52,
    /// L70, L86) - what a text field displays after seeding.
    public static func displayedText(_ stored: String?) -> String { stored ?? "" }
}

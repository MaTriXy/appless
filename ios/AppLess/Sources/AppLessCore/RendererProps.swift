//
//  RendererProps.swift
//  AppLessCore
//
//  Decoders and pure-data rules for the prop shapes the Cupertino renderers
//  consume, ported from `src/genos/ui/cupertino/components.tsx` and
//  `forms.tsx`.
//
//  Everything here is a VALUE decision (which icon, which color slot, which
//  padding, which rows survive filtering), so it lives in `AppLessCore` where a
//  Linux test can pin it against the TypeScript source. `AppLessUI` only turns
//  the results into views.
//
//  NO SwiftUI in this file.
//

import Foundation
import OpenUILang

// MARK: - Shared prop shapes

/// The contract's `{src, alt}` image object (`contract.tsx` L32, L36-39).
public struct ImageRef: Sendable, Equatable {
    public let src: String
    public let alt: String?

    public init(src: String, alt: String? = nil) {
        self.src = src
        self.alt = alt
    }
}

/// `ListItem.leading`: an icon name (colored badge), a thumbnail, or nothing.
/// `components.tsx` L189-196.
public enum ListItemLeading: Sendable, Equatable {
    /// A Lucide icon name - drawn as a tinted rounded badge.
    case icon(String)
    /// A `{src, alt}` thumbnail.
    case image(ImageRef)
    /// Absent, wrong-typed, or an empty string / `src` - draw nothing.
    case none
}

/// One `KVList.rows` entry (`contract.tsx` L303).
public struct KVRow: Sendable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// One `StatTiles.items` entry (`contract.tsx` L328-333).
public struct StatTile: Sendable, Equatable {

    /// How a `delta` string colors itself. `components.tsx` L413-417.
    public enum DeltaSign: Sendable, Equatable {
        /// Trimmed delta starts with `+` - green.
        case positive
        /// Trimmed delta starts with `-` - red.
        case negative
        /// Anything else - secondary ink.
        case neutral

        /// Color slot for this sign in the active theme.
        public func color(_ theme: CdsTheme) -> CdsColor {
            switch self {
            case .positive: return theme.green
            case .negative: return theme.red
            case .neutral: return theme.ink2
            }
        }
    }

    public let label: String
    public let value: String
    public let delta: String?
    public let icon: String?

    public init(label: String, value: String, delta: String? = nil, icon: String? = nil) {
        self.label = label
        self.value = value
        self.delta = delta
        self.icon = icon
    }

    /// `it.delta?.trim().startsWith("-") ? red : startsWith("+") ? green : ink2`
    /// - note the RN order tests `-` FIRST. `components.tsx` L413-417.
    public var deltaSign: DeltaSign {
        guard let trimmed = delta?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .neutral
        }
        if trimmed.hasPrefix("-") { return .negative }
        if trimmed.hasPrefix("+") { return .positive }
        return .neutral
    }
}

/// One `Bubbles.messages` entry (`contract.tsx` L361-367).
public struct BubbleMessage: Sendable, Equatable {
    public let text: String
    public let me: Bool
    public let time: String?

    public init(text: String, me: Bool = false, time: String? = nil) {
        self.text = text
        self.me = me
        self.time = time
    }
}

// MARK: - TextCallout

/// `TextCallout.variant` - picks the leading disc's icon and color.
/// `components.tsx` L118-138.
public enum CalloutVariant: String, Sendable, Equatable, CaseIterable {
    case neutral
    case info
    case success
    case warning
    case danger

    /// Unknown / missing variant falls back to `neutral` (`props.variant ?? "neutral"`,
    /// and `CALLOUT_ICON[variant]` for an unknown string would be undefined - the
    /// port keeps the row renderable by treating it as neutral).
    public static func from(_ raw: String?) -> CalloutVariant {
        guard let raw, let variant = CalloutVariant(rawValue: raw) else { return .neutral }
        return variant
    }

    /// `CALLOUT_ICON` - `components.tsx` L118-124.
    public var iconName: String {
        switch self {
        case .neutral, .info: return "info"
        case .success: return "circle-check"
        case .warning: return "triangle-alert"
        case .danger: return "octagon-alert"
        }
    }

    /// Amber, only used by `warning`. `components.tsx` L135.
    public static let warningColor = CdsColor("#ff9f0a")
    /// Grey, only used by `neutral`. `components.tsx` L138.
    public static let neutralColor = CdsColor("#8e8e93")

    /// Background of the 28pt leading disc. `components.tsx` L129-138.
    public func iconBackground(_ theme: CdsTheme) -> CdsColor {
        switch self {
        case .info: return theme.tint
        case .success: return theme.green
        case .warning: return CalloutVariant.warningColor
        case .danger: return theme.red
        case .neutral: return CalloutVariant.neutralColor
        }
    }
}

// MARK: - Buttons

/// Everything `Button`'s `variant` / `type` / `size` props decide.
/// `forms.tsx` L232-267.
public struct ButtonAppearance: Sendable, Equatable {

    public enum Variant: String, Sendable, Equatable, CaseIterable {
        case primary
        case secondary
        case tertiary
    }

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case normal
        case destructive
    }

    /// The `#fff` label color of a primary button. `forms.tsx` L246.
    public static let onPrimary = CdsColor("#ffffff")

    public let variant: Variant
    public let kind: Kind
    /// `size === "extra-small" || size === "small"`. `forms.tsx` L247.
    public let isCompact: Bool

    public init(variant: String?, type: String?, size: String?) {
        self.variant = variant.flatMap(Variant.init(rawValue:)) ?? .primary
        self.kind = type.flatMap(Kind.init(rawValue:)) ?? .normal
        self.isCompact = size == "extra-small" || size == "small"
    }

    /// Fill color, or `nil` for a transparent (tertiary) button.
    /// `forms.tsx` L238-245.
    public func background(_ theme: CdsTheme) -> CdsColor? {
        switch variant {
        case .primary: return kind == .destructive ? theme.red : theme.tint
        case .secondary: return theme.fill
        case .tertiary: return nil
        }
    }

    /// Label color. `forms.tsx` L246.
    public func foreground(_ theme: CdsTheme) -> CdsColor {
        if variant == .primary { return ButtonAppearance.onPrimary }
        return kind == .destructive ? theme.red : theme.tint
    }

    /// `forms.tsx` L263.
    public var textStyle: CdsMetrics.TextStyle {
        isCompact ? CdsMetrics.Typography.buttonCompact : CdsMetrics.Typography.button
    }

    /// `forms.tsx` L255.
    public var paddingVertical: Double {
        isCompact
            ? CdsMetrics.Spacing.buttonPaddingVerticalCompact
            : CdsMetrics.Spacing.buttonPaddingVertical
    }
}

// MARK: - Text inputs

/// Keyboard/behavior derived from an `Input`'s `type`.
/// Port of `textInputBehaviorProps` (`shared/forms.ts` L38-53).
public enum InputBehavior {

    /// Contract `type` → RN `keyboardType`.
    public enum Keyboard: String, Sendable, Equatable, CaseIterable {
        case `default`
        case email
        case numeric
        case url
    }

    /// `secureTextEntry: type === "password"`.
    public static func isSecure(_ type: String?) -> Bool { type == "password" }

    /// `KEYBOARD[type ?? "text"] ?? "default"`.
    public static func keyboard(_ type: String?) -> Keyboard {
        switch type {
        case "email": return .email
        case "number": return .numeric
        case "url": return .url
        default: return .default
        }
    }

    /// `autoCapitalize: (type === "email" || type === "url") ? "none" : "sentences"`.
    public static func autocapitalizes(_ type: String?) -> Bool {
        !(type == "email" || type == "url")
    }
}

/// `DatePicker` / `TextArea` / `Select` sizing rules.
public enum FieldMetrics {

    /// `props.mode === "range" ? "YYYY-MM-DD → YYYY-MM-DD" : "YYYY-MM-DD"`.
    /// `forms.tsx` L84.
    public static func datePickerPlaceholder(mode: String?) -> String {
        mode == "range" ? "YYYY-MM-DD → YYYY-MM-DD" : "YYYY-MM-DD"
    }

    /// `rows ?? 4`, then `minHeight: 24 + rows * 20`. `forms.tsx` L63, L66.
    public static func textAreaRows(_ rows: Int?) -> Int { rows ?? 4 }
    public static func textAreaMinHeight(rows: Int?) -> Double {
        24 + Double(textAreaRows(rows)) * 20
    }

    /// `SELECT_SIZES[props.size ?? "medium"] ?? SELECT_SIZES.medium`.
    /// `forms.tsx` L95-99, L105.
    public static func selectSize(_ size: String?) -> (paddingVertical: Double, fontSize: Double) {
        CdsMetrics.Typography.selectSizes[size ?? "medium"]
            ?? CdsMetrics.Typography.selectSizes["medium"]!
    }
}

// MARK: - Decoders

/// Prop decoding for the Cupertino renderers. Every function mirrors an RN
/// guard (`Array.isArray(...) ? ... : []`, `.filter(Boolean)`, `!!x`) so a
/// model-emitted prop of the wrong shape degrades exactly the way it does in
/// React Native: the row disappears, the screen does not.
public enum GenosProps {

    // MARK: Text

    /// `TextContent` paints `small` in secondary ink and everything else in
    /// primary ink. `components.tsx` L112.
    public static func textContentIsSecondary(style: String?) -> Bool {
        style == "small"
    }

    // MARK: Images

    /// A `{src, alt}` object, or `nil` when `src` is missing / not a
    /// non-empty string.
    public static func imageRef(_ value: PropValue?) -> ImageRef? {
        guard let object = value?.objectValue,
              let src = object["src"]?.stringValue,
              !src.isEmpty
        else { return nil }
        return ImageRef(src: src, alt: object["alt"]?.stringValue)
    }

    /// `PhotoGrid.images` - `(props.images ?? []).filter((im) => im?.src)`.
    /// `components.tsx` L509.
    public static func imageRefs(_ value: PropValue?) -> [ImageRef] {
        (value?.arrayValue ?? []).compactMap(imageRef)
    }

    /// `ListItem.leading` - `components.tsx` L189-196.
    public static func listItemLeading(_ value: PropValue?) -> ListItemLeading {
        if let name = value?.stringValue {
            // `typeof leading === "string" && leading` - "" is falsy.
            return name.isEmpty ? .none : .icon(name)
        }
        if let image = imageRef(value) { return .image(image) }
        return .none
    }

    // MARK: Rows

    /// `KVList.rows` - `(props.rows ?? []).filter(Boolean)`. `components.tsx` L328.
    ///
    /// The filter is JS TRUTHINESS, not "is an object": a truthy non-object
    /// entry survives it and then renders a row whose two `<Text>` children
    /// are `undefined`, i.e. a blank row that still costs a separator and its
    /// padding. Dropping it instead (the previous behavior) shortened the list
    /// and moved every later separator.
    ///
    /// A missing `label` / `value` reads as `""`; a numeric one reads as its
    /// digits, because `<Text>{r.value}</Text>` renders numbers.
    public static func kvRows(_ value: PropValue?) -> [KVRow] {
        (value?.arrayValue ?? []).filter(\.isJSTruthy).map { entry in
            let object = entry.objectValue
            return KVRow(
                label: object?["label"]?.jsText ?? "",
                value: object?["value"]?.jsText ?? ""
            )
        }
    }

    /// `StatTiles.items` - `(Array.isArray(items) ? items : []).filter(Boolean)`.
    /// `components.tsx` L409. Same truthiness rule as ``kvRows(_:)``.
    public static func statTiles(_ value: PropValue?) -> [StatTile] {
        (value?.arrayValue ?? []).filter(\.isJSTruthy).map { entry in
            let object = entry.objectValue
            return StatTile(
                label: object?["label"]?.jsText ?? "",
                value: object?["value"]?.jsText ?? "",
                // `!!it.delta` / `!!it.icon` gate the two optional slots, so an
                // empty string reads the same as an absent prop.
                delta: object?["delta"].flatMap { $0.isJSTruthy ? $0.jsText : nil },
                icon: object?["icon"].flatMap { $0.isJSTruthy ? $0.jsText : nil }
            )
        }
    }

    /// `Bubbles.messages` - `(props.messages ?? []).filter((m) => m?.text)`;
    /// an empty `text` is falsy and drops the bubble, and so does a non-object
    /// entry (a string has no `.text`). `components.tsx` L531.
    public static func bubbleMessages(_ value: PropValue?) -> [BubbleMessage] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  let raw = object["text"], raw.isJSTruthy,
                  let text = raw.jsText
            else { return nil }
            return BubbleMessage(
                text: text,
                me: object["me"]?.isJSTruthy ?? false,
                // `!!m.time` - an empty time string shows no divider.
                time: object["time"].flatMap { $0.isJSTruthy ? $0.jsText : nil }
            )
        }
    }

    /// `Chips.labels` - `(props.labels ?? []).filter(Boolean)`.
    /// `components.tsx` L577.
    ///
    /// The filter drops `""`, `0`, `false` and `null`; everything else keeps
    /// its slot, including a number, which the chip then prints. A truthy
    /// value React cannot paint (`true`, an object) leaves an empty chip -
    /// which is what RN draws.
    public static func chipLabels(_ value: PropValue?) -> [String] {
        (value?.arrayValue ?? []).filter(\.isJSTruthy).map { $0.jsText ?? "" }
    }

    // MARK: Slider

    /// The slider's live value: `Array.isArray(field.value) ? Number(field.value[0])
    /// : (props.defaultValue?.[0] ?? props.min)`. `forms.tsx` L180-182.
    public static func sliderValue(
        fieldValue: [Double]?,
        defaultValue: [Double]?,
        min: Double
    ) -> Double {
        if let first = fieldValue?.first { return first }
        return defaultValue?.first ?? min
    }

    /// `props.variant === "discrete" ? (props.step ?? 1) : 0` - a step of 0
    /// means "continuous". `forms.tsx` L191.
    public static func sliderStep(variant: String?, step: Double?) -> Double {
        variant == "discrete" ? (step ?? 1) : 0
    }

    /// `Math.round(current * 100) / 100` - the read-out next to the track.
    /// `forms.tsx` L208.
    ///
    /// `JSNumber.round`, not Swift's `rounded()`: JS rounds a half toward
    /// +infinity, so a slider whose range dips below zero reports
    /// `Math.round(-0.5) === -0` where `(-0.5).rounded()` is `-1`.
    public static func sliderReadout(_ value: Double) -> Double {
        JSNumber.round(value * 100) / 100
    }
}

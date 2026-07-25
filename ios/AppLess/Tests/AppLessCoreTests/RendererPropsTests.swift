import Foundation
import OpenUILang
import Testing

@testable import AppLessCore

/// Pins the prop-decoding rules the Cupertino renderers rely on against
/// `src/genos/ui/cupertino/components.tsx` and `forms.tsx`.
@Suite struct RendererPropsTests {

    // MARK: - ListItem.leading

    @Test func leadingStringIsAnIconBadge() {
        #expect(GenosProps.listItemLeading(.string("wifi")) == .icon("wifi"))
    }

    @Test func leadingEmptyStringIsNothing() {
        // `typeof leading === "string" && leading` - "" is falsy in RN.
        #expect(GenosProps.listItemLeading(.string("")) == .none)
    }

    @Test func leadingObjectWithSrcIsAThumbnail() {
        let value = PropValue.object(["src": .string("/api/img?q=cat"), "alt": .string("Cat")])
        #expect(
            GenosProps.listItemLeading(value)
                == .image(ImageRef(src: "/api/img?q=cat", alt: "Cat")))
    }

    @Test func leadingObjectWithoutSrcIsNothing() {
        #expect(GenosProps.listItemLeading(.object(["alt": .string("Cat")])) == .none)
        #expect(GenosProps.listItemLeading(.object(["src": .string("")])) == .none)
        #expect(GenosProps.listItemLeading(nil) == .none)
        #expect(GenosProps.listItemLeading(.null) == .none)
        #expect(GenosProps.listItemLeading(.number(3)) == .none)
    }

    // MARK: - Rows

    @Test func kvRowsDropNonObjectEntries() {
        let rows = PropValue.array([
            .object(["label": .string("Total"), "value": .string("$12")]),
            .null,
            .string("nope"),
            .object(["label": .string("Tax")]),
        ])
        let decoded = GenosProps.kvRows(rows)
        #expect(decoded.count == 2)
        #expect(decoded[0] == KVRow(label: "Total", value: "$12"))
        #expect(decoded[1] == KVRow(label: "Tax", value: ""))
    }

    @Test func statTileDeltaSignFollowsTheRNOrder() {
        #expect(StatTile(label: "a", value: "b", delta: "+12%").deltaSign == .positive)
        #expect(StatTile(label: "a", value: "b", delta: "-3").deltaSign == .negative)
        #expect(StatTile(label: "a", value: "b", delta: "  -3 ").deltaSign == .negative)
        #expect(StatTile(label: "a", value: "b", delta: "flat").deltaSign == .neutral)
        #expect(StatTile(label: "a", value: "b", delta: nil).deltaSign == .neutral)
        #expect(StatTile(label: "a", value: "b", delta: "").deltaSign == .neutral)
    }

    @Test func statTileDeltaColorsComeFromTheTheme() {
        let theme = CdsTheme.light
        #expect(StatTile.DeltaSign.positive.color(theme) == theme.green)
        #expect(StatTile.DeltaSign.negative.color(theme) == theme.red)
        #expect(StatTile.DeltaSign.neutral.color(theme) == theme.ink2)
    }

    @Test func bubbleMessagesDropEmptyText() {
        let messages = PropValue.array([
            .object(["text": .string("hi"), "me": .bool(true), "time": .string("9:41")]),
            .object(["text": .string("")]),
            .object(["me": .bool(true)]),
            .object(["text": .string("ok")]),
        ])
        let decoded = GenosProps.bubbleMessages(messages)
        #expect(decoded.count == 2)
        #expect(decoded[0] == BubbleMessage(text: "hi", me: true, time: "9:41"))
        #expect(decoded[1] == BubbleMessage(text: "ok", me: false, time: nil))
    }

    @Test func photoGridDropsImagesWithoutSrc() {
        let images = PropValue.array([
            .object(["src": .string("a")]),
            .object(["src": .string("")]),
            .null,
            .object(["src": .string("b"), "alt": .string("B")]),
        ])
        #expect(
            GenosProps.imageRefs(images) == [ImageRef(src: "a"), ImageRef(src: "b", alt: "B")])
    }

    @Test func chipLabelsDropEmptyStrings() {
        let labels = PropValue.array([.string("All"), .string(""), .number(2), .string("Unread")])
        #expect(GenosProps.chipLabels(labels) == ["All", "Unread"])
    }

    // MARK: - TextContent / TextCallout

    @Test func textContentStylesMatchTheRNTable() {
        // TEXT_STYLES, components.tsx L93-105.
        #expect(CdsMetrics.Typography.textContentStyle("small").fontSize == 12.5)
        #expect(CdsMetrics.Typography.textContentStyle("default").fontSize == 15)
        #expect(CdsMetrics.Typography.textContentStyle("large").fontSize == 17)
        #expect(CdsMetrics.Typography.textContentStyle("small-heavy").fontWeight == .semibold)
        #expect(CdsMetrics.Typography.textContentStyle("large-heavy").fontWeight == .bold)
        // Unknown / missing falls back to `default`.
        #expect(
            CdsMetrics.Typography.textContentStyle("bogus")
                == CdsMetrics.Typography.textContentStyle(nil))
        // Only `small` is secondary ink.
        #expect(GenosProps.textContentIsSecondary(style: "small"))
        #expect(!GenosProps.textContentIsSecondary(style: "small-heavy"))
        #expect(!GenosProps.textContentIsSecondary(style: nil))
    }

    @Test func calloutVariantsMapToIconsAndColors() {
        let theme = CdsTheme.light
        #expect(CalloutVariant.from(nil) == .neutral)
        #expect(CalloutVariant.from("nonsense") == .neutral)
        #expect(CalloutVariant.neutral.iconName == "info")
        #expect(CalloutVariant.info.iconName == "info")
        #expect(CalloutVariant.success.iconName == "circle-check")
        #expect(CalloutVariant.warning.iconName == "triangle-alert")
        #expect(CalloutVariant.danger.iconName == "octagon-alert")

        #expect(CalloutVariant.info.iconBackground(theme) == theme.tint)
        #expect(CalloutVariant.success.iconBackground(theme) == theme.green)
        #expect(CalloutVariant.danger.iconBackground(theme) == theme.red)
        #expect(CalloutVariant.warning.iconBackground(theme).raw == "#ff9f0a")
        #expect(CalloutVariant.neutral.iconBackground(theme).raw == "#8e8e93")
    }

    @Test func everyCalloutIconResolvesToAnSFSymbol() {
        for variant in CalloutVariant.allCases {
            #expect(
                IconMap.resolve(variant.iconName).symbolName != nil,
                "\(variant.iconName) must not fall back to the placeholder dot")
        }
    }

    // MARK: - Buttons

    @Test func buttonAppearanceMatchesTheRNBranches() {
        let theme = CdsTheme.light
        let primary = ButtonAppearance(variant: nil, type: nil, size: nil)
        #expect(primary.variant == .primary)
        #expect(primary.background(theme) == theme.tint)
        #expect(primary.foreground(theme).raw == "#ffffff")
        #expect(!primary.isCompact)

        let destructive = ButtonAppearance(variant: "primary", type: "destructive", size: "small")
        #expect(destructive.background(theme) == theme.red)
        #expect(destructive.foreground(theme).raw == "#ffffff")
        #expect(destructive.isCompact)
        #expect(destructive.paddingVertical == CdsMetrics.Spacing.buttonPaddingVerticalCompact)

        let secondary = ButtonAppearance(variant: "secondary", type: nil, size: "large")
        #expect(secondary.background(theme) == theme.fill)
        #expect(secondary.foreground(theme) == theme.tint)
        #expect(!secondary.isCompact)

        let tertiaryDestructive = ButtonAppearance(
            variant: "tertiary", type: "destructive", size: "extra-small")
        #expect(tertiaryDestructive.background(theme) == nil)
        #expect(tertiaryDestructive.foreground(theme) == theme.red)
        #expect(tertiaryDestructive.isCompact)

        // Unknown enum strings fall back to the documented defaults.
        #expect(ButtonAppearance(variant: "ghost", type: "x", size: "y").variant == .primary)
        #expect(ButtonAppearance(variant: "ghost", type: "x", size: "y").kind == .normal)
    }

    // MARK: - Inputs

    @Test func inputBehaviorMatchesTextInputBehaviorProps() {
        #expect(InputBehavior.isSecure("password"))
        #expect(!InputBehavior.isSecure("text"))
        #expect(InputBehavior.keyboard("email") == .email)
        #expect(InputBehavior.keyboard("number") == .numeric)
        #expect(InputBehavior.keyboard("url") == .url)
        #expect(InputBehavior.keyboard("text") == .default)
        #expect(InputBehavior.keyboard(nil) == .default)
        #expect(InputBehavior.keyboard("password") == .default)
        #expect(!InputBehavior.autocapitalizes("email"))
        #expect(!InputBehavior.autocapitalizes("url"))
        #expect(InputBehavior.autocapitalizes("text"))
        #expect(InputBehavior.autocapitalizes(nil))
    }

    @Test func fieldMetricsMatchTheRNFormulas() {
        #expect(FieldMetrics.datePickerPlaceholder(mode: "range") == "YYYY-MM-DD → YYYY-MM-DD")
        #expect(FieldMetrics.datePickerPlaceholder(mode: "single") == "YYYY-MM-DD")
        #expect(FieldMetrics.datePickerPlaceholder(mode: nil) == "YYYY-MM-DD")

        #expect(FieldMetrics.textAreaRows(nil) == 4)
        #expect(FieldMetrics.textAreaMinHeight(rows: nil) == 24 + 4 * 20)
        #expect(FieldMetrics.textAreaMinHeight(rows: 2) == 64)

        #expect(FieldMetrics.selectSize(nil).paddingVertical == 12)
        #expect(FieldMetrics.selectSize("small").fontSize == 13)
        #expect(FieldMetrics.selectSize("large").paddingVertical == 15)
        // Unknown size → medium.
        #expect(FieldMetrics.selectSize("huge").fontSize == 15)
    }

    @Test func sliderValueFollowsTheRNFallbackChain() {
        #expect(GenosProps.sliderValue(fieldValue: [7], defaultValue: [3], min: 1) == 7)
        #expect(GenosProps.sliderValue(fieldValue: nil, defaultValue: [3], min: 1) == 3)
        #expect(GenosProps.sliderValue(fieldValue: nil, defaultValue: nil, min: 1) == 1)
        #expect(GenosProps.sliderValue(fieldValue: [], defaultValue: nil, min: 1) == 1)

        #expect(GenosProps.sliderStep(variant: "discrete", step: nil) == 1)
        #expect(GenosProps.sliderStep(variant: "discrete", step: 5) == 5)
        #expect(GenosProps.sliderStep(variant: "continuous", step: 5) == 0)
        #expect(GenosProps.sliderStep(variant: nil, step: nil) == 0)

        #expect(GenosProps.sliderReadout(3.14159) == 3.14)
        #expect(GenosProps.sliderReadout(2) == 2)
    }
}

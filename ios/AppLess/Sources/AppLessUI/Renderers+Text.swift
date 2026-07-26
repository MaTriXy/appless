//
//  Renderers+Text.swift
//  AppLessUI
//
//  Card, CardHeader, TextContent, TextCallout.
//  Port of `src/genos/ui/cupertino/components.tsx` L55-176.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import OpenUILang
import SwiftUI

// MARK: - Card

/// Root of every screen: children stack vertically with a 15pt gap.
/// `components.tsx` L55-57.
struct CardView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        VStack(alignment: .leading, spacing: CdsMetrics.Spacing.cardGap) {
            ctx.render(PropReader(node).children)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, CdsMetrics.Spacing.cardPaddingBottom)
    }
}

// MARK: - CardHeader

/// iOS large title with an optional uppercase eyebrow above it.
/// `components.tsx` L60-91.
struct CardHeaderView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        VStack(alignment: .leading, spacing: 0) {
            if p.isTruthy("subtitle"), let subtitle = p.text("subtitle") {
                Text(subtitle)
                    .textCase(.uppercase)
                    .cdsTextStyle(CdsMetrics.Typography.headerSubtitle)
                    .foregroundStyle(Color(ctx.theme.ink2))
                    .padding(.bottom, 1)
            }
            Text(p.text("title") ?? "")
                .cdsTextStyle(CdsMetrics.Typography.headerTitle)
                .foregroundStyle(Color(ctx.theme.ink))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, CdsMetrics.Spacing.headerPaddingTop)
        .padding(.bottom, CdsMetrics.Spacing.headerPaddingBottom)
        .padding(.horizontal, CdsMetrics.Spacing.headerPaddingHorizontal)
    }
}

// MARK: - TextContent

/// Body text in one of five sizes; only `small` uses secondary ink.
/// `components.tsx` L107-116.
struct TextContentView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        let key = p.string("style")
        let style = CdsMetrics.Typography.textContentStyle(key)
        let isSecondary = GenosProps.textContentIsSecondary(style: key)
        Text(p.text("text") ?? "")
            .cdsTextStyle(style)
            .foregroundStyle(Color(isSecondary ? ctx.theme.ink2 : ctx.theme.ink))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CdsMetrics.Spacing.headerPaddingHorizontal)
            // `large-heavy` pulls the next block up. components.tsx L103.
            .padding(
                .bottom,
                key == "large-heavy" ? CdsMetrics.Typography.largeHeavyMarginBottom : 0)
    }
}

// MARK: - TextCallout

/// Notification-style banner: tinted disc, title, optional description.
/// `components.tsx` L126-176.
struct TextCalloutView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        let variant = CalloutVariant.from(p.string("variant"))
        HStack(alignment: .top, spacing: CdsMetrics.Spacing.calloutGap) {
            Circle()
                .fill(Color(variant.iconBackground(ctx.theme)))
                .frame(
                    width: CdsMetrics.Size.calloutIcon,
                    height: CdsMetrics.Size.calloutIcon)
                .overlay {
                    LucideIcon(
                        variant.iconName,
                        size: CdsMetrics.Size.calloutGlyph,
                        tint: .white)
                }
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(p.text("title") ?? "")
                    .cdsTextStyle(CdsMetrics.Typography.calloutTitle)
                    .foregroundStyle(Color(ctx.theme.ink))
                    .fixedSize(horizontal: false, vertical: true)
                if p.isTruthy("description"), let description = p.text("description") {
                    Text(description)
                        .cdsTextStyle(CdsMetrics.Typography.calloutBody)
                        .foregroundStyle(Color(ctx.theme.ink2))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, CdsMetrics.Spacing.calloutPaddingVertical)
        .padding(.horizontal, CdsMetrics.Spacing.calloutPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cdsGroupSurface(ctx.theme, radius: CdsMetrics.Radius.group)
    }
}

#endif

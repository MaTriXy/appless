//
//  Renderers+Lists.swift
//  AppLessUI
//
//  ListItem, Toggle, ListBlock, KVList.
//  Port of `src/genos/ui/cupertino/components.tsx` L179-365.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import OpenUILang
import SwiftUI

// MARK: - ListItem

/// Tappable settings-style row: leading badge or thumbnail, title + subtitle,
/// trailing value, chevron. `components.tsx` L179-225.
struct ListItemView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        let action = p.action("action")
        if ListItemPresentation.isInteractive(action: action) {
            Button {
                // `useTap` dispatches with NO form name (`shared/actions.ts`
                // L14), so a row tap always carries the whole-store snapshot.
                ctx.scoped(formName: ListItemPresentation.dispatchesWithFormName)
                    .trigger(p.text("title") ?? "", action: action)
            } label: {
                row(p, showsChevron: true)
            }
            .buttonStyle(RowPressStyle(theme: ctx.theme))
        } else {
            // No action → inert. RN's `Pressable` is `disabled` and shows no
            // chevron, so the row reads as informational.
            row(p, showsChevron: false)
        }
    }

    @ViewBuilder
    private func row(_ p: PropReader, showsChevron: Bool) -> some View {
        HStack(spacing: CdsMetrics.Spacing.rowGap) {
            switch GenosProps.listItemLeading(p.value("leading")) {
            case .icon(let name):
                IconBadge(name)
            case .image(let image):
                SemanticImageView(src: image.src, placeholder: Color(ctx.theme.fill))
                    .frame(
                        width: CdsMetrics.Size.thumbnail,
                        height: CdsMetrics.Size.thumbnail)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: CdsMetrics.Radius.thumbnail, style: .continuous))
            case .none:
                EmptyView()
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(p.text("title") ?? "")
                    .cdsTextStyle(CdsMetrics.Typography.rowTitle)
                    .foregroundStyle(Color(ctx.theme.ink))
                    .lineLimit(1)
                if p.isTruthy("subtitle"), let subtitle = p.text("subtitle") {
                    Text(subtitle)
                        .cdsTextStyle(CdsMetrics.Typography.rowSubtitle)
                        .foregroundStyle(Color(ctx.theme.ink2))
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if p.isTruthy("trailing"), let trailing = p.text("trailing") {
                // No `lineLimit`: RN sets `numberOfLines={1}` on the title and
                // the subtitle (components.tsx L199, L206) but NOT on the
                // trailing value (L213-217), so a long one wraps rather than
                // being truncated.
                Text(trailing)
                    .cdsTextStyle(CdsMetrics.Typography.rowTrailing)
                    .foregroundStyle(Color(ctx.theme.ink2))
                    .monospacedDigit()
            }

            if showsChevron {
                LucideIcon(
                    "chevron-right",
                    size: CdsMetrics.Size.rowChevron,
                    tint: Color(ctx.theme.ink3)
                )
                .padding(.leading, CdsMetrics.Spacing.rowChevronOffset)
            }
        }
        .padding(.vertical, CdsMetrics.Spacing.rowPaddingVertical)
        .padding(.leading, CdsMetrics.Spacing.rowPaddingLeading)
        .padding(.trailing, CdsMetrics.Spacing.rowPaddingTrailing)
        .frame(minHeight: CdsMetrics.Spacing.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Toggle

/// iOS switch row. Flips LOCALLY with no round trip - the contract promises
/// "flips instantly on tap, no round trip". `components.tsx` L227-281.
struct ToggleView: View {
    let node: ElementNode
    let ctx: RenderContext

    /// `useState<boolean | null>(null)`: `nil` means "still showing the value
    /// the model sent", so a re-render with a new `on` prop is respected until
    /// the user touches the switch. `components.tsx` L229-230.
    @State private var override: Bool?

    var body: some View {
        let p = PropReader(node)
        let isOn = override ?? (p.value("on")?.isJSTruthy ?? false)
        Button {
            override = !isOn
        } label: {
            HStack(spacing: CdsMetrics.Spacing.rowGap) {
                if p.isTruthy("icon"), let icon = p.text("icon") {
                    IconBadge(icon)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.text("title") ?? "")
                        .cdsTextStyle(CdsMetrics.Typography.rowTitle)
                        .foregroundStyle(Color(ctx.theme.ink))
                        .lineLimit(1)
                    if p.isTruthy("subtitle"), let subtitle = p.text("subtitle") {
                        Text(subtitle)
                            .cdsTextStyle(CdsMetrics.Typography.rowSubtitle)
                            .foregroundStyle(Color(ctx.theme.ink2))
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                switchTrack(isOn: isOn)
            }
            .padding(.vertical, CdsMetrics.Spacing.rowPaddingVertical)
            .padding(.leading, CdsMetrics.Spacing.rowPaddingLeading)
            .padding(.trailing, CdsMetrics.Spacing.rowPaddingTrailing)
            .frame(minHeight: CdsMetrics.Spacing.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowPressStyle(theme: ctx.theme))
        // RN sets `accessibilityRole="switch"` + `accessibilityState`;
        // `AccessibilityTraits.isToggle` is iOS 17, so the on/off state is
        // announced as the button's value instead.
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }

    /// The hand-drawn 47×28 track. RN draws its own switch rather than using
    /// the platform control, and the port matches it so light/dark and the
    /// green fill stay identical across design systems.
    private func switchTrack(isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: CdsMetrics.Radius.toggleTrack, style: .continuous)
            .fill(Color(isOn ? ctx.theme.green : ctx.theme.fill))
            .frame(
                width: CdsMetrics.Size.toggleTrackWidth,
                height: CdsMetrics.Size.toggleTrackHeight)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(
                        width: CdsMetrics.Size.toggleKnob,
                        height: CdsMetrics.Size.toggleKnob)
                    .shadow(color: .black.opacity(0.25), radius: 2.5, x: 0, y: 2)
                    .padding(2)
            }
            .animation(.easeInOut(duration: 0.18), value: isOn)
    }
}

// MARK: - ListBlock

/// Inset grouped list of `ListItem` / `Toggle` rows, separated by hairlines.
/// `components.tsx` L308-324.
struct ListBlockView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        let items = p.elementList("items")
        VStack(alignment: .leading, spacing: 0) {
            if p.isTruthy("header"), let header = p.text("header") {
                GroupHeaderLabel(text: header, theme: ctx.theme)
            }
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    if index > 0 { RowSeparator(theme: ctx.theme) }
                    GenosNodeView(node: items[index], context: ctx)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cdsGroupSurface(ctx.theme)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - KVList

/// Compact label/value details group. `components.tsx` L326-365.
struct KVListView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        let rows = GenosProps.kvRows(p.value("rows"))
        VStack(alignment: .leading, spacing: 0) {
            if p.isTruthy("header"), let header = p.text("header") {
                GroupHeaderLabel(text: header, theme: ctx.theme)
            }
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { RowSeparator(theme: ctx.theme) }
                    HStack(alignment: .firstTextBaseline, spacing: CdsMetrics.Spacing.kvRowGap) {
                        Text(rows[index].label)
                            .cdsTextStyle(CdsMetrics.Typography.kvKey)
                            .foregroundStyle(Color(ctx.theme.ink2))
                        Text(rows[index].value)
                            .cdsTextStyle(CdsMetrics.Typography.kvValue)
                            .foregroundStyle(Color(ctx.theme.ink))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.vertical, CdsMetrics.Spacing.kvRowPaddingVertical)
                    .padding(.horizontal, CdsMetrics.Spacing.kvRowPaddingHorizontal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cdsGroupSurface(ctx.theme)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif

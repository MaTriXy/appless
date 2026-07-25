//
//  Renderers+Media.swift
//  AppLessUI
//
//  ImageBlock, PhotoGrid, Bubbles, Chips, Tabs.
//  Port of `src/genos/ui/cupertino/components.tsx` L463-676.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import OpenUILang
import SwiftUI

// MARK: - ImageBlock

/// Full-width 16:9 hero image; the caption overlays the bottom on a gradient.
/// `components.tsx` L463-505.
struct ImageBlockView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        Color.clear
            .aspectRatio(CdsMetrics.Size.imageBlockAspectRatio, contentMode: .fit)
            .overlay {
                SemanticImageView(src: p.string("src"), placeholder: Color(ctx.theme.fill))
            }
            .overlay(alignment: .bottom) {
                if p.isTruthy("caption"), let caption = p.string("caption") {
                    Text(caption)
                        .cdsTextStyle(CdsMetrics.Typography.imageCaption)
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, CdsMetrics.Spacing.captionPaddingTop)
                        .padding(.horizontal, CdsMetrics.Spacing.captionPaddingHorizontal)
                        .padding(.bottom, CdsMetrics.Spacing.captionPaddingBottom)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.62)],
                                startPoint: .top,
                                endPoint: .bottom)
                        )
                }
            }
            .background(Color(ctx.theme.fill))
            .clipShape(RoundedRectangle(cornerRadius: CdsMetrics.Radius.media, style: .continuous))
    }
}

// MARK: - PhotoGrid

/// Three-column square photo grid. `components.tsx` L507-526.
///
/// Same `flexWrap` reasoning as `StatTiles`: chunks of three, and a short last
/// row stretches - which is what `flexGrow: 1` on a `flexBasis: 31%` tile does.
struct PhotoGridView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let images = GenosProps.imageRefs(PropReader(node).value("images"))
        let rows = images.cdsChunked(into: 3)
        VStack(spacing: CdsMetrics.Spacing.photoGridGap) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: CdsMetrics.Spacing.photoGridGap) {
                    ForEach(rows[rowIndex].indices, id: \.self) { columnIndex in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                SemanticImageView(
                                    src: rows[rowIndex][columnIndex].src,
                                    placeholder: Color(ctx.theme.fill))
                            }
                            .clipped()
                    }
                }
            }
        }
        .background(Color(ctx.theme.fill))
        .clipShape(RoundedRectangle(cornerRadius: CdsMetrics.Radius.media, style: .continuous))
    }
}

// MARK: - Bubbles

/// Chat thread. `me: true` bubbles sit right on the tint, everyone else's sit
/// left on the bubble grey; a `time` string becomes a centered divider above
/// the bubble. `components.tsx` L529-570.
struct BubblesView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let messages = GenosProps.bubbleMessages(PropReader(node).value("messages"))
        WidthReader { width in
            VStack(spacing: CdsMetrics.Spacing.bubbleGap) {
                ForEach(messages.indices, id: \.self) { index in
                    let message = messages[index]
                    if let time = message.time {
                        Text(time)
                            .cdsTextStyle(CdsMetrics.Typography.bubbleAuthor)
                            .foregroundStyle(Color(ctx.theme.ink2))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, CdsMetrics.Spacing.bubbleTimeMarginTop)
                            .padding(.bottom, CdsMetrics.Spacing.bubbleTimeMarginBottom)
                    }
                    bubble(message, maxWidth: bubbleMaxWidth(in: width))
                        .frame(
                            maxWidth: .infinity,
                            alignment: message.me ? .trailing : .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CdsMetrics.Spacing.bubblePaddingHorizontalOuter)
        }
    }

    /// `maxWidth: "78%"`. Before the first layout pass the width is unknown, so
    /// the cap is simply not applied - the bubble is never invisible.
    private func bubbleMaxWidth(in width: CGFloat) -> CGFloat? {
        guard width > 0 else { return nil }
        return width * CdsMetrics.Spacing.bubbleMaxWidthFraction
    }

    private func bubble(_ message: BubbleMessage, maxWidth: CGFloat?) -> some View {
        Text(message.text)
            .cdsTextStyle(CdsMetrics.Typography.bubbleBody)
            .foregroundStyle(
                message.me ? Color(ButtonAppearance.onPrimary) : Color(ctx.theme.ink))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, CdsMetrics.Spacing.bubblePaddingVertical)
            .padding(.horizontal, CdsMetrics.Spacing.bubblePaddingHorizontal)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(Color(message.me ? ctx.theme.tint : ctx.theme.bubble))
            .clipShape(BubbleShape(isMine: message.me))
    }
}

/// The asymmetric bubble: 18pt corners everywhere except the tail, which is 6.
/// `components.tsx` L555-559.
struct BubbleShape: Shape {
    let isMine: Bool

    func path(in rect: CGRect) -> Path {
        let big = CGFloat(CdsMetrics.Radius.bubble)
        let tail = CGFloat(CdsMetrics.Radius.bubbleTail)
        let topLeft = big
        let topRight = big
        let bottomRight = isMine ? tail : big
        let bottomLeft = isMine ? big : tail

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
            radius: topRight,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(
            center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
            radius: bottomRight,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
            radius: bottomLeft,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(
            center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
            radius: topLeft,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Chips

/// Horizontal filter pills. LIVE: tapping a chip regenerates the screen with
/// the chip's label as the request - no `action` prop is involved.
/// `components.tsx` L573-621.
struct ChipsView: View {
    let node: ElementNode
    let ctx: RenderContext

    @State private var active = 0

    var body: some View {
        let labels = GenosProps.chipLabels(PropReader(node).value("labels"))
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CdsMetrics.Spacing.chipGap) {
                ForEach(labels.indices, id: \.self) { index in
                    Button {
                        // Re-tapping the active chip is a no-op (it would ask
                        // the model to re-render the screen it is already on).
                        guard index != active else { return }
                        active = index
                        ctx.scoped(formName: nil)
                            .trigger(GenosActions.chipsMessage(labels[index]))
                    } label: {
                        Text(labels[index])
                            .cdsTextStyle(CdsMetrics.Typography.chip)
                            .foregroundStyle(
                                Color(index == active ? ctx.theme.bg : ctx.theme.ink)
                            )
                            .padding(.vertical, CdsMetrics.Spacing.chipPaddingVertical)
                            .padding(.horizontal, CdsMetrics.Spacing.chipPaddingHorizontal)
                            .background(
                                Capsule().fill(
                                    Color(index == active ? ctx.theme.ink : ctx.theme.group))
                            )
                            .overlay {
                                if index != active {
                                    Capsule()
                                        .stroke(
                                            Color(ctx.theme.sep),
                                            lineWidth: CdsMetrics.Size.hairline)
                                }
                            }
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }
            .padding(.vertical, CdsMetrics.Spacing.chipsPaddingVertical)
            .padding(.horizontal, CdsMetrics.Spacing.chipsBleed)
        }
        // The scroller bleeds past the screen's gutter so chips run edge to
        // edge. components.tsx L582.
        .padding(.horizontal, -CdsMetrics.Spacing.chipsBleed)
    }
}

// MARK: - Tabs

/// Segmented control that swaps `TabItem` contents LOCALLY - no round trip.
/// `components.tsx` L623-676.
struct TabsView: View {
    let node: ElementNode
    let ctx: RenderContext

    @State private var active = 0

    var body: some View {
        let items = StructuralProps.tabItems(of: node)
        // `items[Math.min(active, max(items.length - 1, 0))]` - a shrinking
        // tab list must not strand the selection out of range.
        let current = items.isEmpty ? nil : items[min(active, items.count - 1)]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CdsMetrics.Spacing.tabTrackGap) {
                ForEach(items.indices, id: \.self) { index in
                    Button {
                        active = index
                    } label: {
                        Text(items[index].label.isEmpty ? "Tab \(index + 1)" : items[index].label)
                            .cdsTextStyle(CdsMetrics.Typography.tab)
                            .foregroundStyle(Color(ctx.theme.ink))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CdsMetrics.Spacing.tabPaddingVertical)
                            .padding(.horizontal, CdsMetrics.Spacing.tabPaddingHorizontal)
                            .background {
                                if index == min(active, max(items.count - 1, 0)) {
                                    RoundedRectangle(
                                        cornerRadius: CdsMetrics.Radius.segment,
                                        style: .continuous
                                    )
                                    .fill(Color(ctx.theme.group))
                                    .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 1)
                                }
                            }
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }
            .padding(CdsMetrics.Spacing.tabTrackPadding)
            .background(
                RoundedRectangle(
                    cornerRadius: CdsMetrics.Radius.segmentTrack, style: .continuous
                )
                .fill(Color(ctx.theme.fill))
            )

            if let current {
                VStack(alignment: .leading, spacing: CdsMetrics.Spacing.tabContentGap) {
                    ctx.render(current.children)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, CdsMetrics.Spacing.tabContentMarginTop)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif

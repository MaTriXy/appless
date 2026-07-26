//
//  Renderers+Stats.swift
//  AppLessUI
//
//  HeroStat, StatTiles.
//  Port of `src/genos/ui/cupertino/components.tsx` L368-460.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import OpenUILang
import SwiftUI

// MARK: - HeroStat

/// One huge centered number - the screen's headline stat.
/// `components.tsx` L368-405.
struct HeroStatView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        VStack(spacing: 0) {
            if p.isTruthy("label"), let label = p.text("label") {
                Text(label)
                    .textCase(.uppercase)
                    .cdsTextStyle(CdsMetrics.Typography.heroLabel)
                    .foregroundStyle(Color(ctx.theme.ink2))
                    .padding(.bottom, 2)
            }
            Text(p.text("value") ?? "")
                .cdsTextStyle(CdsMetrics.Typography.heroValue)
                .foregroundStyle(Color(ctx.theme.ink))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if p.isTruthy("sublabel"), let sublabel = p.text("sublabel") {
                Text(sublabel)
                    .cdsTextStyle(CdsMetrics.Typography.heroCaption)
                    .foregroundStyle(Color(ctx.theme.ink2))
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, CdsMetrics.Spacing.heroPaddingTop)
        .padding(.bottom, CdsMetrics.Spacing.heroPaddingBottom)
    }
}

// MARK: - StatTiles

/// Grid of 2-4 KPI tiles. `components.tsx` L407-460.
///
/// RN lays the tiles out with `flexWrap` + `flexBasis: 45%` + `flexGrow: 1`,
/// which fills two per row and lets a lone trailing tile stretch to the full
/// width. The port chunks into pairs and lets each tile take an equal share of
/// its row, which reproduces both behaviors exactly.
struct StatTilesView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let items = GenosProps.statTiles(PropReader(node).value("items"))
        // `flexWrap` + `flexBasis: 45%` + `flexGrow: 1` = two per row, and a
        // lone trailing tile stretches. `FlexWrap` owns the row split.
        let rows = FlexWrap.rows(count: items.count, perRow: 2)
        VStack(spacing: CdsMetrics.Spacing.tileGap) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: CdsMetrics.Spacing.tileGap) {
                    ForEach(rows[rowIndex], id: \.self) { itemIndex in
                        tile(items[itemIndex])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ item: StatTile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CdsMetrics.Spacing.tileLabelGap) {
                if let icon = item.icon, !icon.isEmpty {
                    LucideIcon(
                        icon,
                        size: CdsMetrics.Size.tileGlyph,
                        tint: Color(ctx.theme.ink2))
                }
                Text(item.label)
                    .cdsTextStyle(CdsMetrics.Typography.tileLabel)
                    .foregroundStyle(Color(ctx.theme.ink2))
            }
            HStack(alignment: .firstTextBaseline, spacing: CdsMetrics.Spacing.tileValueGap) {
                Text(item.value)
                    .cdsTextStyle(CdsMetrics.Typography.tileValue)
                    .foregroundStyle(Color(ctx.theme.ink))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let delta = item.delta, !delta.isEmpty {
                    Text(delta)
                        .cdsTextStyle(CdsMetrics.Typography.tileDelta)
                        .foregroundStyle(Color(item.deltaSign.color(ctx.theme)))
                }
            }
            .padding(.top, CdsMetrics.Spacing.tileValueMarginTop)
        }
        .padding(.vertical, CdsMetrics.Spacing.tilePaddingVertical)
        .padding(.horizontal, CdsMetrics.Spacing.tilePaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cdsGroupSurface(ctx.theme)
    }
}

#endif

//
//  IconView.swift
//  AppLessUI
//
//  Draws an icon name resolved by `AppLessCore.IconMap`, including the
//  mandatory unknown-name degradation from spec/icon-map.md §1.
//

#if canImport(SwiftUI)

import AppLessCore
import SwiftUI

/// A Lucide icon name rendered as an SF Symbol, degrading to a neutral
/// placeholder dot for names outside the mapped tables.
///
/// spec/icon-map.md §1: "Native ports MUST degrade to an equivalent neutral dot
/// (or design-approved placeholder), never crash or hide the row."
public struct LucideIcon: View {
    public let name: String
    public let size: CGFloat
    public let tint: Color

    public init(
        _ name: String,
        size: CGFloat = CdsMetrics.Size.iconDefault,
        tint: Color
    ) {
        self.name = name
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        switch IconMap.resolve(name) {
        case .symbol(let symbol):
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
        case .placeholderDot:
            // 8x8, corner radius 4, caller tint at 0.6 opacity.
            RoundedRectangle(cornerRadius: CdsMetrics.Size.placeholderDotRadius, style: .continuous)
                .fill(tint)
                .opacity(CdsMetrics.Size.placeholderDotOpacity)
                .frame(
                    width: CdsMetrics.Size.placeholderDot,
                    height: CdsMetrics.Size.placeholderDot
                )
        }
    }
}

/// The rounded icon badge used by `ListItem` / `Toggle` rows - the iOS
/// settings-row look. `components.tsx` L34-49.
public struct IconBadge: View {
    public let name: String

    public init(_ name: String) { self.name = name }

    public var body: some View {
        RoundedRectangle(cornerRadius: CdsMetrics.Radius.iconBadge, style: .continuous)
            .fill(Color(IconMap.iconTint(name)))
            .frame(width: CdsMetrics.Size.iconBadge, height: CdsMetrics.Size.iconBadge)
            .overlay {
                LucideIcon(name, size: CdsMetrics.Size.iconBadgeGlyph, tint: .white)
            }
    }
}

#endif

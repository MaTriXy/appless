//
//  Renderers+Support.swift
//  AppLessUI
//
//  Small pieces every renderer group shares: the semantic image element, the
//  grouped-list chrome (separator, section header, surface), the press styles,
//  and the width reader the proportional layouts need.
//
//  Values still come from `AppLessCore` - this file only bridges them.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import OpenUILang
import SwiftUI

// MARK: - Semantic images

/// The shared `Img` element (`shared/media.tsx`): resolves an `/api/img?...`
/// reference through `GenOSCore`'s image tool and fills its frame, showing the
/// themed placeholder until the bitmap arrives.
struct SemanticImageView: View {
    let src: String?
    let placeholder: Color

    var body: some View {
        switch SemanticImage.resolve(src) {
        case .url(let resolved):
            if let url = URL(string: resolved) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        case .pending, .none:
            placeholder
        }
    }
}

// MARK: - Grouped-list chrome

/// Inset hairline between grouped rows. `components.tsx` L283-287.
struct RowSeparator: View {
    let theme: CdsTheme

    var body: some View {
        Rectangle()
            .fill(Color(theme.sep))
            .frame(height: CdsMetrics.Size.hairline)
            .padding(.leading, CdsMetrics.Spacing.separatorInset)
    }
}

/// Small uppercase section label above a `ListBlock` / `KVList`.
/// `components.tsx` L289-306.
struct GroupHeaderLabel: View {
    let text: String
    let theme: CdsTheme

    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .cdsTextStyle(CdsMetrics.Typography.groupHeader)
            .foregroundStyle(Color(theme.ink2))
            .padding(.leading, CdsMetrics.Spacing.groupHeaderMarginLeading)
            .padding(.bottom, CdsMetrics.Spacing.groupHeaderMarginBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// The grouped surface every card-like block sits on: `t.group` fill,
    /// 14pt continuous corners, clipped children.
    func cdsGroupSurface(
        _ theme: CdsTheme,
        radius: Double = CdsMetrics.Radius.group
    ) -> some View {
        background(Color(theme.group))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// A field's hairline border. `forms.tsx` L30-33.
    func cdsFieldBorder(_ theme: CdsTheme) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: CdsMetrics.Radius.field, style: .continuous)
                .stroke(Color(theme.sep), lineWidth: CdsMetrics.Size.hairline)
        )
    }
}

// MARK: - Press feedback

/// A grouped row: the whole row highlights with `t.fill` while pressed.
/// `components.tsx` L187.
struct RowPressStyle: ButtonStyle {
    let theme: CdsTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(theme.fill) : Color.clear)
            .contentShape(Rectangle())
    }
}

/// A form button: dims and shrinks slightly while pressed.
/// `forms.tsx` L258-260.
struct ButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Rectangle())
    }
}

/// A chip / segment: no chrome of its own, just a hit area.
struct PlainPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Width reader

/// Hands its content the width it was laid out in.
///
/// SwiftUI has no proportional `flexBasis`, and the layouts that need one
/// (a chat bubble capped at 78% of the thread) cannot be expressed with
/// stacks alone. The measurement is published from `onAppear` / `onChange`
/// rather than a `PreferenceKey` so nothing runs during layout.
struct WidthReader<Content: View>: View {
    @State private var width: CGFloat = 0
    let content: (CGFloat) -> Content

    init(@ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.content = content
    }

    var body: some View {
        content(width)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { newWidth in width = newWidth }
                }
            )
    }
}

// Row splitting for the `flexWrap` layouts (`StatTiles`, `PhotoGrid`, the
// chart legend) lives in `AppLessCore.FlexWrap`, where a Linux test can pin
// the short-last-row behavior.

#endif

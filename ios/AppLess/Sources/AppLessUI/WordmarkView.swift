//
//  WordmarkView.swift
//  AppLessUI
//
//  The AppLess wordmark. RN hands `APPLESS_LOGO_XML` to `react-native-svg`;
//  SwiftUI has no SVG reader, so `AppLessCore.AppLessWordmark` carries the
//  parsed path and this view only replays it into a `Path`, scaled to fit.
//

#if canImport(SwiftUI)

import AppLessCore
import SwiftUI

/// The wordmark as a `Shape`, so it can be filled, masked or animated like
/// any other SwiftUI geometry.
public struct WordmarkShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        for command in AppLessWordmark.commands {
            switch command {
            case .move(let x, let y):
                path.move(to: CGPoint(x: x, y: y))
            case .line(let x, let y):
                path.addLine(to: CGPoint(x: x, y: y))
            case .curve(let c1x, let c1y, let c2x, let c2y, let x, let y):
                path.addCurve(
                    to: CGPoint(x: x, y: y),
                    control1: CGPoint(x: c1x, y: c1y),
                    control2: CGPoint(x: c2x, y: c2y))
            case .closeSubpath:
                path.closeSubpath()
            }
        }
        // The commands are in viewBox space; scale them into `rect` the way
        // SVG's default `preserveAspectRatio="xMidYMid meet"` would.
        let boxWidth = CGFloat(AppLessWordmark.viewBoxWidth)
        let boxHeight = CGFloat(AppLessWordmark.viewBoxHeight)
        let scale = min(rect.width / boxWidth, rect.height / boxHeight)
        let width = boxWidth * scale
        let height = boxHeight * scale
        let transform = CGAffineTransform(
            translationX: rect.minX + (rect.width - width) / 2,
            y: rect.minY + (rect.height - height) / 2
        ).scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }
}

/// The wordmark at its home-screen size (RN `SvgXml width={170} height={44}`).
public struct WordmarkView: View {
    public let width: CGFloat
    public let height: CGFloat
    public let tint: Color

    public init(
        width: CGFloat = ShellChrome.Home.wordmarkWidth,
        height: CGFloat = ShellChrome.Home.wordmarkHeight,
        tint: Color = Color(AppLessWordmark.fill)
    ) {
        self.width = width
        self.height = height
        self.tint = tint
    }

    public var body: some View {
        WordmarkShape()
            .fill(tint)
            .frame(width: width, height: height)
            .accessibilityLabel(Text("AppLess"))
    }
}

#endif

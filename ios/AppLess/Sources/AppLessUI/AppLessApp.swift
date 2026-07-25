//
//  AppLessApp.swift
//  AppLessUI
//
//  The app entry point. Compiles on macOS/iOS only; on Linux this file is
//  empty, which is what keeps `swift build` green in CI without Xcode.
//
//  See README.md ("Opening it in Xcode") for how to run this.
//

#if canImport(SwiftUI)

import AppLessCore
import GenOSCore
import SwiftUI

@main
public struct AppLessApp: App {
    public init() {
        registerCupertinoRenderers()
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Root of the shell. The Cupertino renderers are wired, so this reports
/// `renderers registered: 30/30`; it stays in place until the GenOS shell
/// (home screen, screen stack, ask bar) lands and starts rendering real
/// screens through ``GenosScreenView``.
public struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private var theme: CdsTheme { CdsTheme.resolve(isDark: colorScheme == .dark) }

    public var body: some View {
        let report = RendererRegistry.shared.conformanceReport()
        ScrollView {
            VStack(alignment: .leading, spacing: CdsMetrics.Spacing.cardGap) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("APPLESS")
                        .cdsTextStyle(CdsMetrics.Typography.headerSubtitle)
                        .foregroundStyle(Color(theme.ink2))
                    Text("Renderers")
                        .cdsTextStyle(CdsMetrics.Typography.headerTitle)
                        .foregroundStyle(Color(theme.ink))
                }
                .padding(.top, CdsMetrics.Spacing.headerPaddingTop)
                .padding(.bottom, CdsMetrics.Spacing.headerPaddingBottom)

                Text(report.formatted())
                    .cdsTextStyle(CdsMetrics.Typography.rowSubtitle)
                    .foregroundStyle(Color(theme.ink2))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(CdsMetrics.Spacing.calloutPaddingHorizontal)
                    .background(
                        RoundedRectangle(cornerRadius: CdsMetrics.Radius.group, style: .continuous)
                            .fill(Color(theme.group))
                    )
            }
            .padding(.horizontal, CdsMetrics.Spacing.cardGap)
            .padding(.bottom, CdsMetrics.Spacing.cardPaddingBottom)
        }
        .background(Color(theme.bg).ignoresSafeArea())
        .cdsTheme(colorScheme: colorScheme)
    }
}

#endif

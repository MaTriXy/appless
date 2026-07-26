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

/// Boots the runtime, then hands over to ``GenOSShellView``.
///
/// The contract schema and the generated system prompt are bundle resources of
/// the HOST app target (they are never copied into this package - see
/// `AppLessConfiguration.load`). Until they are there, the shell cannot parse a
/// screen, so the diagnostics view explains exactly that instead of showing an
/// empty home screen that can never generate anything.
public struct RootView: View {

    private enum Boot {
        case loading
        case ready(GenOSShellModel)
        case failed(String)
    }

    @State private var boot: Boot = .loading
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        Group {
            switch boot {
            case .loading:
                Color(CdsTheme.resolve(isDark: colorScheme == .dark).bg)
                    .ignoresSafeArea()
            case .ready(let model):
                GenOSShellView(model: model)
            case .failed(let message):
                SetupDiagnosticsView(message: message)
            }
        }
        .onAppear { start() }
    }

    @MainActor
    private func start() {
        guard case .loading = boot else { return }
        // Renderers register once; the App's init already did it, but a
        // preview or a host app that instantiates RootView directly has not.
        registerCupertinoRenderers()
        do {
            let configuration = try AppLessConfiguration.load()
            boot = .ready(AppLessRuntime.makeModel(configuration: configuration))
        } catch {
            boot = .failed(String(describing: error))
        }
    }
}

/// Why the shell could not boot, plus the renderer conformance report - the
/// same gate line CI greps (`renderers registered: 30/30`).
struct SetupDiagnosticsView: View {
    let message: String

    @Environment(\.colorScheme) private var colorScheme

    private var theme: CdsTheme { CdsTheme.resolve(isDark: colorScheme == .dark) }

    var body: some View {
        let report = RendererRegistry.shared.conformanceReport()
        ScrollView {
            VStack(alignment: .leading, spacing: CdsMetrics.Spacing.cardGap) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("APPLESS")
                        .cdsTextStyle(CdsMetrics.Typography.headerSubtitle)
                        .foregroundStyle(Color(theme.ink2))
                    Text("Setup")
                        .cdsTextStyle(CdsMetrics.Typography.headerTitle)
                        .foregroundStyle(Color(theme.ink))
                }
                .padding(.top, CdsMetrics.Spacing.headerPaddingTop)
                .padding(.bottom, CdsMetrics.Spacing.headerPaddingBottom)

                callout(message)
                callout(report.formatted())
            }
            .padding(.horizontal, CdsMetrics.Spacing.cardGap)
            .padding(.bottom, CdsMetrics.Spacing.cardPaddingBottom)
        }
        .background(Color(theme.bg).ignoresSafeArea())
        .cdsTheme(colorScheme: colorScheme)
    }

    private func callout(_ text: String) -> some View {
        Text(text)
            .cdsTextStyle(CdsMetrics.Typography.rowSubtitle)
            .foregroundStyle(Color(theme.ink2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CdsMetrics.Spacing.calloutPaddingHorizontal)
            .background(
                RoundedRectangle(cornerRadius: CdsMetrics.Radius.group, style: .continuous)
                    .fill(Color(theme.group))
            )
    }
}

#endif

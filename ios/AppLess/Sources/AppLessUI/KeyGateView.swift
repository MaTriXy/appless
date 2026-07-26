//
//  KeyGateView.swift
//  AppLessUI
//
//  First-launch gate: AppLess is BYOK - screens generate on the user's own
//  Cerebras key, entered once and stored on-device (Keychain). Shown until a
//  key exists, and again if the API rejects the stored one.
//
//  Port of `src/genos/shell/KeyGate.tsx`; `GenOSCore.KeyStore` owns the
//  status machine and the persistence.
//

#if canImport(SwiftUI)

import AppLessCore
import GenOSCore
import SwiftUI

struct KeyGateView: View {
    let status: KeyStatus
    let theme: CdsTheme
    let onSubmit: (String) -> Void

    @Environment(\.openURL) private var openURL
    @State private var value: String = ""
    @State private var saving = false

    private var valid: Bool { ShellChrome.KeyGate.isSubmittable(value) }

    var body: some View {
        ZStack {
            Color(theme.bg).ignoresSafeArea()
            VStack(spacing: ShellChrome.KeyGate.gap) {
                Text(ShellChrome.KeyGate.title)
                    .font(.system(size: ShellChrome.KeyGate.titleFontSize, weight: .heavy))
                    .tracking(ShellChrome.KeyGate.titleLetterSpacing)
                    .foregroundStyle(Color(theme.ink))

                Text(ShellChrome.KeyGate.blurb)
                    .font(.system(size: ShellChrome.KeyGate.blurbFontSize))
                    .foregroundStyle(Color(theme.ink2))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: ShellChrome.KeyGate.blurbMaxWidth)

                if ShellChrome.KeyGate.showsRejectedNotice(status) {
                    Text(ShellChrome.KeyGate.rejectedNotice)
                        .font(.system(size: ShellChrome.KeyGate.noticeFontSize))
                        .foregroundStyle(Color(theme.red))
                        .multilineTextAlignment(.center)
                }

                field
                startButton
                signupLink
            }
            .padding(ShellChrome.KeyGate.padding)
        }
    }

    private var field: some View {
        TextField("", text: $value)
            .textFieldStyle(.plain)
            .font(.system(size: ShellChrome.KeyGate.fieldFontSize))
            .foregroundStyle(Color(theme.ink))
            .autocorrectionDisabled(true)
            .modifier(AskFieldPlatformModifier())
            .onSubmit { save() }
            .padding(.vertical, ShellChrome.KeyGate.fieldPaddingVertical)
            .padding(.horizontal, ShellChrome.KeyGate.fieldPaddingHorizontal)
            .background(alignment: .leading) {
                if value.isEmpty {
                    Text(ShellChrome.KeyGate.placeholder)
                        .font(.system(size: ShellChrome.KeyGate.fieldFontSize))
                        .foregroundStyle(Color(theme.ink3))
                        .padding(.leading, ShellChrome.KeyGate.fieldPaddingHorizontal)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: ShellChrome.KeyGate.fieldRadius, style: .continuous)
                    .fill(Color(theme.group))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ShellChrome.KeyGate.fieldRadius, style: .continuous)
                    .stroke(Color(theme.sep), lineWidth: CdsMetrics.Size.hairline)
            )
            .frame(maxWidth: ShellChrome.KeyGate.fieldMaxWidth)
    }

    private var startButton: some View {
        Button(action: { save() }) {
            Text(ShellChrome.KeyGate.buttonLabel(saving: saving))
                .font(.system(size: ShellChrome.KeyGate.buttonFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, ShellChrome.KeyGate.buttonPaddingVertical)
                .padding(.horizontal, ShellChrome.KeyGate.buttonPaddingHorizontal)
                .background(
                    RoundedRectangle(
                        cornerRadius: ShellChrome.KeyGate.buttonRadius, style: .continuous
                    )
                    .fill(Color(ShellChrome.KeyGate.accent))
                )
        }
        .buttonStyle(KeyGatePressStyle())
        .disabled(!valid || saving)
        .opacity(!valid || saving ? ShellChrome.KeyGate.disabledOpacity : 1)
    }

    private var signupLink: some View {
        Button {
            if let url = URL(string: ShellChrome.KeyGate.signupURL) { openURL(url) }
        } label: {
            Text(ShellChrome.KeyGate.signupLabel)
                .font(.system(size: ShellChrome.KeyGate.linkFontSize))
                .foregroundStyle(Color(theme.tint))
        }
        .buttonStyle(PlainPressStyle())
    }

    @MainActor
    private func save() {
        guard valid, !saving else { return }
        saving = true
        onSubmit(value)
    }
}

/// RN `opacity: pressed ? 0.8 : 1` (the disabled dimming is applied outside,
/// so the two do not multiply).
struct KeyGatePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? ShellChrome.KeyGate.pressedOpacity : 1)
            .contentShape(Rectangle())
    }
}

#endif

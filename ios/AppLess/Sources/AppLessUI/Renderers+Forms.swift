//
//  Renderers+Forms.swift
//  AppLessUI
//
//  Form, FormControl, Input, TextArea, Select, DatePicker, Slider, Buttons,
//  Button. Port of `src/genos/ui/cupertino/forms.tsx`.
//
//  Field values flow into the shared `GenosFormStore` keyed by the enclosing
//  `Form`'s name (react-lang's `FormNameContext` + state store), wrapped
//  `{value, componentType}` on submit. Each input also keeps a local `@State`
//  mirror so typing stays responsive without re-rendering the whole screen -
//  the store is the source of truth at SUBMIT time, the mirror during editing.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import OpenUILang
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Field chrome

/// The shared input box: grouped fill, hairline border, 12pt corners.
/// `useInputStyle`, `forms.tsx` L27-39.
private struct FieldBox: ViewModifier {
    let theme: CdsTheme
    let paddingVertical: Double

    func body(content: Content) -> some View {
        content
            .padding(.vertical, paddingVertical)
            .padding(.horizontal, CdsMetrics.Spacing.fieldPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(theme.group))
            .clipShape(
                RoundedRectangle(cornerRadius: CdsMetrics.Radius.field, style: .continuous)
            )
            .cdsFieldBorder(theme)
    }
}

extension View {
    fileprivate func cdsFieldBox(
        _ theme: CdsTheme,
        paddingVertical: Double = CdsMetrics.Spacing.fieldPaddingVertical
    ) -> some View {
        modifier(FieldBox(theme: theme, paddingVertical: paddingVertical))
    }
}

/// Keyboard behavior from the contract's `type`. `textInputBehaviorProps`,
/// `shared/forms.ts` L38-53. iOS-only modifiers are guarded so the same file
/// still compiles for macOS CI.
private struct TextInputBehavior: ViewModifier {
    let type: String?

    func body(content: Content) -> some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        content
            .keyboardType(keyboardType)
            .textInputAutocapitalization(
                InputBehavior.autocapitalizes(type) ? .sentences : .never
            )
            .autocorrectionDisabled(!InputBehavior.autocapitalizes(type))
        #else
        content
        #endif
    }

    #if canImport(UIKit)
    private var keyboardType: UIKeyboardType {
        switch InputBehavior.keyboard(type) {
        case .default: return .default
        case .email: return .emailAddress
        case .numeric: return .numberPad
        case .url: return .URL
        }
    }
    #endif
}

/// A placeholder drawn behind the field, since SwiftUI has no placeholder
/// color before iOS 17. `forms.tsx` passes `placeholderTextColor={t.ink3}`.
private struct PlaceholderOverlay: View {
    let text: String
    let isVisible: Bool
    let theme: CdsTheme
    let fontSize: Double

    var body: some View {
        if isVisible, !text.isEmpty {
            Text(text)
                .font(.system(size: fontSize))
                .foregroundStyle(Color(theme.ink3))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Input

/// Single-line text field. `forms.tsx` L42-57.
struct InputView: View {
    let node: ElementNode
    let ctx: RenderContext

    @State private var text = ""

    var body: some View {
        let p = PropReader(node)
        let name = p.string("name") ?? ""
        let type = p.string("type")
        let placeholder = p.text("placeholder") ?? ""
        ZStack(alignment: .leading) {
            PlaceholderOverlay(
                text: placeholder,
                isVisible: text.isEmpty,
                theme: ctx.theme,
                fontSize: CdsMetrics.Typography.fieldText.fontSize)
            if InputBehavior.isSecure(type) {
                SecureField("", text: $text)
                    .textFieldStyle(.plain)
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .modifier(TextInputBehavior(type: type))
            }
        }
        .font(CdsMetrics.Typography.fieldText.font)
        .foregroundStyle(Color(ctx.theme.ink))
        .cdsFieldBox(ctx.theme)
        .onAppear { text = seedField(ctx: ctx, name: name, componentType: "Input", prop: p.value("value")) }
        .onChange(of: text) { newValue in
            ctx.forms.set(
                form: ctx.formName, name: name, componentType: "Input",
                value: .string(newValue))
        }
    }
}

// MARK: - TextArea

/// Multi-line text field; `rows` sets the minimum height. `forms.tsx` L59-75.
struct TextAreaView: View {
    let node: ElementNode
    let ctx: RenderContext

    @State private var text = ""

    var body: some View {
        let p = PropReader(node)
        let name = p.string("name") ?? ""
        let placeholder = p.text("placeholder") ?? ""
        let minHeight = FieldMetrics.textAreaMinHeight(rows: p.int("rows"))
        ZStack(alignment: .topLeading) {
            PlaceholderOverlay(
                text: placeholder,
                isVisible: text.isEmpty,
                theme: ctx.theme,
                fontSize: CdsMetrics.Typography.fieldText.fontSize)
            .padding(.top, 8)
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight, alignment: .topLeading)
        }
        .font(CdsMetrics.Typography.fieldText.font)
        .foregroundStyle(Color(ctx.theme.ink))
        .cdsFieldBox(ctx.theme)
        .onAppear {
            text = seedField(ctx: ctx, name: name, componentType: "TextArea", prop: p.value("value"))
        }
        .onChange(of: text) { newValue in
            ctx.forms.set(
                form: ctx.formName, name: name, componentType: "TextArea",
                value: .string(newValue))
        }
    }
}

// MARK: - DatePicker

/// The contract's DatePicker is a TEXT field in RN too: an ISO date the model
/// can read back verbatim, with a `range` mode that accepts two of them.
/// `forms.tsx` L77-91.
struct DatePickerView: View {
    let node: ElementNode
    let ctx: RenderContext

    @State private var text = ""

    var body: some View {
        let p = PropReader(node)
        let name = p.string("name") ?? ""
        let placeholder = FieldMetrics.datePickerPlaceholder(mode: p.string("mode"))
        ZStack(alignment: .leading) {
            PlaceholderOverlay(
                text: placeholder,
                isVisible: text.isEmpty,
                theme: ctx.theme,
                fontSize: CdsMetrics.Typography.fieldText.fontSize)
            TextField("", text: $text)
                .textFieldStyle(.plain)
        }
        .font(CdsMetrics.Typography.fieldText.font)
        .foregroundStyle(Color(ctx.theme.ink))
        .cdsFieldBox(ctx.theme)
        .onAppear {
            text = seedField(
                ctx: ctx, name: name, componentType: "DatePicker", prop: p.value("value"))
        }
        .onChange(of: text) { newValue in
            ctx.forms.set(
                form: ctx.formName, name: name, componentType: "DatePicker",
                value: .string(newValue))
        }
    }
}

// MARK: - Select

/// Tap to open the option list; the chosen `SelectItem`'s VALUE goes into form
/// state, its LABEL is what the row shows. `forms.tsx` L101-168.
struct SelectView: View {
    let node: ElementNode
    let ctx: RenderContext

    @State private var selection: String?
    @State private var isOpen = false

    var body: some View {
        let p = PropReader(node)
        let name = p.string("name") ?? ""
        let items = StructuralProps.selectItems(of: node)
        let size = FieldMetrics.selectSize(p.string("size"))
        let selected = SelectPresentation.selected(in: items, value: selection)
        Button {
            isOpen = true
        } label: {
            HStack {
                Text(
                    SelectPresentation.triggerLabel(
                        selected: selected, placeholder: p.text("placeholder"))
                )
                    .font(.system(size: size.fontSize))
                    .foregroundStyle(
                        Color(
                            SelectPresentation.triggerShowsSelection(selected)
                                ? ctx.theme.ink : ctx.theme.ink3))
                    .lineLimit(1)
                Spacer(minLength: 8)
                LucideIcon(
                    "chevrons-up-down",
                    size: CdsMetrics.Size.selectChevron,
                    tint: Color(ctx.theme.ink3))
            }
            .cdsFieldBox(ctx.theme, paddingVertical: size.paddingVertical)
        }
        .buttonStyle(PlainPressStyle())
        .onAppear {
            ctx.forms.seed(
                form: ctx.formName, name: name, componentType: "Select", prop: p.value("value"))
            selection = ctx.forms.value(form: ctx.formName, name: name)?.textValue
        }
        .sheet(isPresented: $isOpen) {
            SelectOptionList(
                items: items,
                selection: selection,
                theme: ctx.theme
            ) { chosen in
                selection = chosen
                ctx.forms.set(
                    form: ctx.formName, name: name, componentType: "Select",
                    value: .string(chosen))
                isOpen = false
            }
        }
    }
}

/// The option list. RN uses a translucent centered `Modal`; SwiftUI's
/// cross-platform equivalent is a sheet, so the list is presented that way.
private struct SelectOptionList: View {
    let items: [StructuralProps.SelectItem]
    let selection: String?
    let theme: CdsTheme
    let onChoose: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    if index > 0 {
                        Rectangle()
                            .fill(Color(theme.sep))
                            .frame(height: CdsMetrics.Size.hairline)
                    }
                    Button {
                        onChoose(items[index].value)
                    } label: {
                        HStack {
                            Text(items[index].optionLabel)
                                .font(CdsMetrics.Typography.fieldText.font)
                                .foregroundStyle(Color(theme.ink))
                            Spacer(minLength: 8)
                            if items[index].value == selection {
                                LucideIcon(
                                    "check",
                                    size: CdsMetrics.Size.selectCheck,
                                    tint: Color(theme.tint))
                            }
                        }
                        .padding(.vertical, CdsMetrics.Spacing.selectRowPaddingVertical)
                        .padding(.horizontal, CdsMetrics.Spacing.selectRowPaddingHorizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(RowPressStyle(theme: theme))
                }
            }
            .cdsGroupSurface(theme)
            .padding(CdsMetrics.Spacing.selectModalInset)
        }
        .background(Color(theme.bg).ignoresSafeArea())
    }
}

// MARK: - Slider

/// Numeric slider with a live read-out. The default is SEEDED into form state
/// so an untouched slider still submits a value. `forms.tsx` L171-213.
struct SliderView: View {
    let node: ElementNode
    let ctx: RenderContext

    @State private var value: Double = 0

    var body: some View {
        let p = PropReader(node)
        let name = p.string("name") ?? ""
        let range = SliderPresentation.bounds(min: p.number("min"), max: p.number("max"))
        let minimum = range.lower
        let upper = range.upper
        let step = GenosProps.sliderStep(variant: p.string("variant"), step: p.number("step"))
        VStack(alignment: .leading, spacing: CdsMetrics.Spacing.sliderGap) {
            if p.isTruthy("label"), let label = p.text("label") {
                Text(label)
                    .font(.system(size: CdsMetrics.Typography.fieldLabel.fontSize))
                    .foregroundStyle(Color(ctx.theme.ink2))
            }
            HStack(spacing: CdsMetrics.Spacing.sliderRowGap) {
                Group {
                    if SliderPresentation.isDiscrete(step: step) {
                        Slider(value: $value, in: minimum...upper, step: step)
                    } else {
                        Slider(value: $value, in: minimum...upper)
                    }
                }
                .frame(height: CdsMetrics.Spacing.sliderTrackHeight)
                .tint(Color(ctx.theme.tint))

                Text(readout)
                    .font(
                        .system(
                            size: CdsMetrics.Typography.fieldLabel.fontSize,
                            weight: .semibold)
                    )
                    .foregroundStyle(Color(ctx.theme.ink2))
                    .monospacedDigit()
                    .frame(
                        width: CdsMetrics.Spacing.sliderReadoutWidth,
                        alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Seed `value ?? defaultValue ?? [min]` exactly like RN, so the
            // field exists in form state before anyone touches it.
            let seed = FieldSeeding.sliderSeed(
                value: p.value("value"), defaultValue: p.value("defaultValue"), min: minimum)
            ctx.forms.seed(
                form: ctx.formName, name: name, componentType: "Slider", prop: seed)
            let stored = ctx.forms.value(form: ctx.formName, name: name)?.numbersValue
            value = GenosProps.sliderValue(
                fieldValue: stored,
                defaultValue: SliderPresentation.defaultValues(p.value("defaultValue")),
                min: minimum)
        }
        .onChange(of: value) { newValue in
            ctx.forms.set(
                form: ctx.formName, name: name, componentType: "Slider",
                value: .numbers([newValue]))
        }
    }

    /// `Math.round(current * 100) / 100`, stringified the way JS does it.
    private var readout: String { SliderPresentation.readoutText(value) }
}

// MARK: - FormControl

/// Label + input + optional hint. `forms.tsx` L216-229.
struct FormControlView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        VStack(alignment: .leading, spacing: CdsMetrics.Spacing.formControlGap) {
            Text(p.text("label") ?? "")
                .cdsTextStyle(CdsMetrics.Typography.fieldLabel)
                .foregroundStyle(Color(ctx.theme.ink2))
                .padding(.leading, CdsMetrics.Spacing.formControlLabelInset)
            ctx.renderNode(p.value("input"))
            if p.isTruthy("hint"), let hint = p.text("hint") {
                Text(hint)
                    .cdsTextStyle(CdsMetrics.Typography.fieldHint)
                    .foregroundStyle(Color(ctx.theme.ink3))
                    .padding(.leading, CdsMetrics.Spacing.formControlLabelInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Buttons

/// One button. Without an `action` it still sends its LABEL - that default is
/// what makes "Submit" work with no plan attached. `forms.tsx` L232-268.
struct ButtonView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        let appearance = ButtonAppearance(
            variant: p.string("variant"),
            type: p.string("type"),
            size: p.string("size"))
        Button {
            // `triggerAction(label ?? "", formName, action)`: the form name
            // comes from the enclosing Form, so the tap carries its values.
            ctx.trigger(p.text("label") ?? "", action: p.action("action"))
        } label: {
            Text(p.text("label") ?? "")
                .cdsTextStyle(appearance.textStyle)
                .foregroundStyle(Color(appearance.foreground(ctx.theme)))
                .padding(.vertical, appearance.paddingVertical)
                .padding(.horizontal, CdsMetrics.Spacing.buttonPaddingHorizontal)
                .frame(maxWidth: .infinity)
                .background {
                    if let background = appearance.background(ctx.theme) {
                        RoundedRectangle(
                            cornerRadius: CdsMetrics.Radius.group, style: .continuous
                        )
                        .fill(Color(background))
                    }
                }
        }
        .buttonStyle(ButtonPressStyle())
    }
}

/// A row (default) or column of buttons. `forms.tsx` L270-281.
struct ButtonsView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        let buttons = p.elementList("buttons")
        let isColumn = ButtonsPresentation.isColumn(direction: p.string("direction"))
        if isColumn {
            VStack(spacing: CdsMetrics.Spacing.buttonsGap) {
                ForEach(buttons.indices, id: \.self) { index in
                    GenosNodeView(node: buttons[index], context: ctx)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: CdsMetrics.Spacing.buttonsGap) {
                ForEach(buttons.indices, id: \.self) { index in
                    GenosNodeView(node: buttons[index], context: ctx)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Form

/// Form container. Its `name` scopes every field inside it, so the buttons
/// deliver exactly those values. `FormNameContext.Provider`, `forms.tsx` L283-292.
struct FormView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        let scoped = ctx.scoped(formName: p.string("name"))
        let fields = p.elementList("fields")
        VStack(alignment: .leading, spacing: CdsMetrics.Spacing.formGap) {
            ForEach(fields.indices, id: \.self) { index in
                GenosNodeView(node: fields[index], context: scoped)
            }
            scoped.renderNode(p.value("buttons"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Seeding

/// Seed a text field from the model-supplied `value` prop, then read back
/// whatever form state actually holds - `useFieldState` + `useSetDefaultValue`
/// (`shared/forms.ts` L19-36).
private func seedField(
    ctx: RenderContext,
    name: String,
    componentType: String,
    prop: PropValue?
) -> String {
    ctx.forms.seed(form: ctx.formName, name: name, componentType: componentType, prop: prop)
    return FieldSeeding.displayedText(ctx.forms.value(form: ctx.formName, name: name)?.textValue)
}

#endif

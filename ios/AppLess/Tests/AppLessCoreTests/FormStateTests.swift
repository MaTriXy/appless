import Foundation
import GenOSCore
import OpenUILang
import Testing

@testable import AppLessCore

/// The form-state model and the `{value, componentType}` payload shape
/// (`spec/openui-lang.md` §9.4).
@Suite struct FormStateTests {

    @Test func fieldsKeepInsertionOrderPerForm() {
        var model = FormStateModel()
        model.set(form: "booking", name: "name", componentType: "Input", value: .string("Ada"))
        model.set(form: "booking", name: "when", componentType: "DatePicker", value: .string("2026-07-25"))
        model.set(form: "booking", name: "name", componentType: "Input", value: .string("Grace"))

        let fields = model.fields(in: "booking")
        #expect(fields.map(\.name) == ["name", "when"])
        #expect(fields[0].value == .string("Grace"))
        #expect(model.formNames == ["booking"])
    }

    @Test func seedDefaultOnlyAppliesOnce() {
        var model = FormStateModel()
        let first = model.seedDefault(
            form: "f", name: "a", componentType: "Input", value: .string("seed"))
        let second = model.seedDefault(
            form: "f", name: "a", componentType: "Input", value: .string("other"))
        #expect(first)
        #expect(!second)
        #expect(model.value(form: "f", name: "a") == .string("seed"))
    }

    @Test func payloadWrapsValuesWithTheirComponentType() {
        var model = FormStateModel()
        model.set(form: "f", name: "email", componentType: "Input", value: .string("a@b.c"))
        model.set(form: "f", name: "size", componentType: "Slider", value: .numbers([4]))

        let payload = model.payload(formName: "f")
        #expect(payload.keys == ["f"])
        #expect(
            payload.stringified
                == #"{"f":{"email":{"componentType":"Input","value":"a@b.c"},"#
                    + #""size":{"componentType":"Slider","value":[4]}}}"#)
    }

    @Test func payloadFallsBackToTheWholeSnapshot() {
        var model = FormStateModel()
        model.set(form: "one", name: "a", componentType: "Input", value: .string("1"))
        model.set(form: "two", name: "b", componentType: "Input", value: .string("2"))

        // No form name → every form, in the order they were first written.
        #expect(model.payload(formName: nil).keys == ["one", "two"])
        // A form name with no data → the whole snapshot, not an empty object.
        #expect(model.payload(formName: "missing").keys == ["one", "two"])
        // A form name WITH data → just that form.
        #expect(model.payload(formName: "two").keys == ["two"])
    }

    @Test func emptyStoreProducesAnEmptyPayload() {
        let model = FormStateModel()
        #expect(model.payload(formName: "anything").isEmpty)
        #expect(model.payload(formName: nil).isEmpty)
        // GenOSCore treats an empty formState as "not a submission".
        #expect(model.payload(formName: nil).pairs.isEmpty)
    }

    @Test func resetClearsNamedFieldsAndPrunesEmptyForms() {
        var model = FormStateModel()
        model.set(form: "f", name: "a", componentType: "Input", value: .string("1"))
        model.set(form: "f", name: "b", componentType: "Input", value: .string("2"))

        model.reset(form: "f", names: ["a"])
        #expect(model.fields(in: "f").map(\.name) == ["b"])

        model.reset(form: "f", names: ["b"])
        #expect(model.fields(in: "f").isEmpty)
        #expect(model.formNames.isEmpty)
    }

    @Test func seedValueDecodingMatchesTheContractPropTypes() {
        #expect(FormValue(seed: .string("hi")) == .string("hi"))
        #expect(FormValue(seed: .number(3)) == .number(3))
        #expect(FormValue(seed: .bool(true)) == .bool(true))
        #expect(FormValue(seed: .array([.number(2), .number(5)])) == .numbers([2, 5]))
        // Absent / null / non-numeric arrays never seed - the field stays
        // missing from form state instead of submitting a bogus value.
        #expect(FormValue(seed: nil) == nil)
        #expect(FormValue(seed: .null) == nil)
        #expect(FormValue(seed: .array([])) == nil)
        #expect(FormValue(seed: .array([.string("x")])) == nil)
    }

    @Test func textValueGuardsAgainstNonStrings() {
        #expect(FormValue.string("a").textValue == "a")
        #expect(FormValue.numbers([1]).textValue == "")
        #expect(FormValue.null.textValue == "")
        #expect(FormValue.numbers([1, 2]).numbersValue == [1, 2])
        #expect(FormValue.number(4).numbersValue == [4])
        #expect(FormValue.string("a").numbersValue == nil)
    }

    @Test func orderedJSONPreservesTopLevelOrder() {
        let ordered = OrderedJSON([("b", .number(1)), ("a", .number(2))])
        #expect(ordered.keys == ["b", "a"])
        #expect(ordered.stringified == #"{"b":1,"a":2}"#)
        #expect(ordered["a"] == .number(2))
        #expect(ordered["zz"] == nil)
    }
}

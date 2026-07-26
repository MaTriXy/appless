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
        // Byte-pinned against node:
        //   const w=(value,componentType)=>({value,componentType});
        //   let f={}; f={...f,email:w("a@b.c","Input")}; f={...f,size:w([4],"Slider")};
        //   JSON.stringify({f})
        // Note `value` BEFORE `componentType` - react-lang builds the wrapper as
        // `const wrapped = { value, componentType }` (`useOpenUIState.js`
        // `setFieldValue`), and `spec/openui-lang.md` §9.4 pins that order.
        #expect(
            payload.stringified
                == #"{"f":{"email":{"value":"a@b.c","componentType":"Input"},"#
                    + #""size":{"value":[4],"componentType":"Slider"}}}"#)
    }

    /// The field level is INSERTION-ordered, not sorted - the case a
    /// `[String: JSONValue]` could not express. Every field here is written in
    /// reverse-alphabetical order, so a sorted serializer produces different
    /// bytes; `zulu` is then overwritten to pin that a re-assignment keeps its
    /// ORIGINAL position (JS `{...formData, [name]: wrapped}` semantics).
    ///
    /// Byte-pinned against node:
    ///   const w=(value,componentType)=>({value,componentType});
    ///   let g={}; g={...g,zulu:w("1","Input")}; g={...g,mike:w("2","Input")};
    ///   g={...g,alpha:w("3","Input")}; g={...g,zulu:w("9","Input")};
    ///   JSON.stringify({g})
    @Test func fieldsSerializeInInsertionOrderNotSorted() {
        var model = FormStateModel()
        model.set(form: "g", name: "zulu", componentType: "Input", value: .string("1"))
        model.set(form: "g", name: "mike", componentType: "Input", value: .string("2"))
        model.set(form: "g", name: "alpha", componentType: "Input", value: .string("3"))
        model.set(form: "g", name: "zulu", componentType: "Input", value: .string("9"))

        #expect(
            model.payload(formName: "g").stringified
                == #"{"g":{"zulu":{"value":"9","componentType":"Input"},"#
                    + #""mike":{"value":"2","componentType":"Input"},"#
                    + #""alpha":{"value":"3","componentType":"Input"}}}"#)
    }

    /// Canonical array-index field names sort NUMERICALLY and hoist ahead of
    /// every string key, at the field level too - `OrdinaryOwnPropertyKeys`
    /// applies to this object like any other. An insertion-ordered
    /// serializer that FORGOT the index hoist would emit them in write order,
    /// so this probes the path the fix does not take.
    ///
    /// Byte-pinned against node:
    ///   const w=(value,componentType)=>({value,componentType});
    ///   let h={}; for (const k of ["b","10","2","a"]) h={...h,[k]:w(k,"Input")};
    ///   JSON.stringify({h})
    @Test func numericFieldNamesStillHoistAndSortNumerically() {
        var model = FormStateModel()
        for name in ["b", "10", "2", "a"] {
            model.set(form: "h", name: name, componentType: "Input", value: .string(name))
        }

        #expect(
            model.payload(formName: "h").stringified
                == #"{"h":{"2":{"value":"2","componentType":"Input"},"#
                    + #""10":{"value":"10","componentType":"Input"},"#
                    + #""b":{"value":"b","componentType":"Input"},"#
                    + #""a":{"value":"a","componentType":"Input"}}}"#)
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

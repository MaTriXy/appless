import Foundation
import OpenUILang
import Testing

/// `PropObject` is public API, so its iteration order is part of the contract.
///
/// It is `Object.keys(o)` order — `OrdinaryOwnPropertyKeys` (ES 10.1.11.1):
/// canonical array indices FIRST in ascending numeric order, then every
/// remaining key in insertion order. Not raw insertion order (which would
/// mis-place index keys) and not the serializer's order (which additionally
/// SORTS the string group, because the reference serializer does
/// `Object.keys(v).sort()` before re-inserting — fixture
/// `075-object-key-index-order` pins that side).
///
/// Not a corpus fixture: the serializer re-orders anyway, so nothing here is
/// tree-observable — this suite exists precisely because a renderer iterating
/// props directly WOULD observe it.
@Suite struct PropObjectKeyOrderTests {

    private func make(_ keys: [String]) -> PropObject {
        PropObject(keys.enumerated().map { ($0.element, PropValue.number(Double($0.offset))) })
    }

    /// Index keys hoist ahead of string keys, numerically — `"10"` after `"2"`.
    @Test func indicesHoistAheadOfStringKeys() {
        let o = make(["beta", "10", "alpha", "2", "0"])
        #expect(o.keys == ["0", "2", "10", "beta", "alpha"])
        #expect(o.entries.map(\.key) == o.keys)
    }

    /// Without any index key the order is plain insertion order.
    @Test func stringOnlyObjectKeepsInsertionOrder() {
        #expect(make(["zeta", "alpha", "mid"]).keys == ["zeta", "alpha", "mid"])
    }

    /// `"4294967295"` is 2^32-1 and therefore NOT an array index; `"01"` has a
    /// redundant leading zero. Both stay in the string group.
    @Test func nonCanonicalDigitStringsStayInTheStringGroup() {
        let o = make(["4294967295", "01", "4294967294", "-0"])
        #expect(o.keys == ["4294967294", "4294967295", "01", "-0"])
    }

    /// A re-assignment keeps the original slot, exactly like JS.
    @Test func rewriteKeepsOriginalPosition() {
        var o = make(["a", "b", "c"])
        o["a"] = .string("again")
        #expect(o.keys == ["a", "b", "c"])
        #expect(o["a"] == .string("again"))
    }

    /// The serializer's order is a DIFFERENT order — string keys sorted, not in
    /// insertion order — and must stay that way.
    @Test func serializerOrderStillSortsTheStringGroup() throws {
        let result = ParseResult(state: ["$s": .object(make(["beta", "10", "alpha", "2"]))])
        let json = TreeSerializer.serialize(result)
        let body = json.components(separatedBy: "\"$s\": {")[1].components(separatedBy: "}")[0]
        let order = body.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let end = trimmed.dropFirst().firstIndex(of: "\"")
            else { return nil }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        }
        #expect(order == ["2", "10", "alpha", "beta"])
    }
}

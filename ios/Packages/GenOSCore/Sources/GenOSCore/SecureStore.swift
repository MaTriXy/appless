import Foundation

/// Key persistence seam. Phase 3 provides a Keychain implementation behind
/// #if canImport(Security); tests inject an in-memory implementation.
public protocol SecureStore: Sendable {
    /// Read the stored value for `key`, nil when absent.
    func read(_ key: String) async throws -> String?
    /// Write `value` for `key`; nil deletes.
    func write(_ key: String, value: String?) async throws
}

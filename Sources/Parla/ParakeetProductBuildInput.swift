import ParlaCore

/// Replaced only in the producer's owned main input tree, before source freeze.
/// A writable Resources descriptor cannot supply this independent expectation.
enum ParakeetProductBuildInput {
    static let expected: ParakeetProductIdentity? = nil
}

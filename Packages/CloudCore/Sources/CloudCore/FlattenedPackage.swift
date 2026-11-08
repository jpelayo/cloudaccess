// Apache 2 license - developer@infinitecontext.com

/// A package, such as a `.numbers` document, is a folder Finder shows as one file. macOS hands it
/// to a drive as one flattened file named `Report.numbers.pkgf`, and puts it on the disk as
/// `Report.numbers`. So one document has two names, and these are the rules for them.
///
/// Only the name says which it is. A `.numbers` document can also be a plain file, so the
/// extension before `.pkgf` proves nothing.
public enum FlattenedPackage {
    private static let suffix = ".pkgf"

    public static func isFlattened(_ name: String) -> Bool {
        name.count > suffix.count && name.hasSuffix(suffix)
    }

    /// The name on the disk, which is the one a person knows.
    public static func shownName(_ name: String) -> String {
        isFlattened(name) ? String(name.dropLast(suffix.count)) : name
    }

    /// The other name that lands in the same place on the disk.
    public static func twin(of name: String) -> String {
        isFlattened(name) ? shownName(name) : name + suffix
    }

    /// What a rename means on the server. Flattened bytes stay flattened whatever macOS asks for,
    /// and without the suffix they'd come back as a plain file nothing can open.
    public static func renamed(_ name: String, to newName: String) -> String {
        guard isFlattened(name), !isFlattened(newName) else { return newName }
        return newName + suffix
    }
}

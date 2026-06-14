// SwiftRAR — native Swift RAR archive reader.
//
// Public API entry points live in `RARArchive.swift`. This file exists so the
// SwiftPM target has at least one source file during package initialization;
// concrete types live in their own files.

import Foundation

/// Package-level namespace marker. Intentionally empty — use `RARArchive`.
public enum SwiftRAR {
    /// Semantic version of the SwiftRAR package itself.
    public static let version = "0.1.0"
}

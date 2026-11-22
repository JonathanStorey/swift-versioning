import Foundation

extension RecordContainer {
    /// The folder holding the asset files of the row `id`, one file for each version that
    /// uses it, so `base`, `ours` and `theirs` can each keep their own file for a merge.
    func assetFolder(id: UUID) -> URL {
        assets.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// `json` with the file at each of `files`, by field, copied into the row's folder under
    /// a new name, and the field pointing at the copy.
    ///
    /// A file already in the folder is kept as it is. A file that cannot be copied keeps
    /// its URL. On APFS the copy is a clone, which shares the original's blocks.
    func storingAssets(_ files: [String: URL], in json: JSONRepresentation, id: UUID) -> JSONRepresentation {
        let folder = assetFolder(id: id)
        var stored: [String: JSONRepresentation] = [:]
        for (key, file) in files where !file.absoluteString.hasPrefix(folder.absoluteString) {
            // Named for its field, so a folder reads at a glance, and unique, so no version's
            // file is ever replaced.
            let copy = folder.appendingPathComponent("\(key)-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: copy)
                stored[key] = .string(copy.absoluteString)
            } catch {
                continue
            }
        }
        return stored.isEmpty ? json : json.replacing(stored)
    }

    /// Removes each file in the row's folder that none of `base`, `ours`, `theirs` and `sent`
    /// points at, and the folder once nothing is left in it.
    func removeUnusedAssets(of row: Row) {
        let folder = assetFolder(id: row.id)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let used = Set([row.base, row.ours, row.theirs, row.sent].compactMap { $0 }.flatMap(\.strings).compactMap { text in
            text.hasPrefix(folder.absoluteString) ? URL(string: text)?.lastPathComponent : nil
        })
        let unused = files.filter { !used.contains($0.lastPathComponent) }
        for file in unused { try? FileManager.default.removeItem(at: file) }
        if unused.count == files.count { try? FileManager.default.removeItem(at: folder) }
    }

    /// Removes the row's folder and every asset file in it.
    func removeAssets(id: UUID) {
        try? FileManager.default.removeItem(at: assetFolder(id: id))
    }

    /// The file of each `Asset` property of `record`, by field: a top-level property, since
    /// a nested value is stored as JSON, where a record cannot hold an asset.
    static func assetFiles(of record: Any) -> [String: URL] {
        var files: [String: URL] = [:]
        for property in Mirror(reflecting: record).properties {
            if let file = (property.value as? any AnyAsset)?.projectedValue { files[property.name] = file }
        }
        return files
    }

    /// `json` with each top-level file in the row's folder named relative to the folder, as
    /// the table stores it, so the database still finds its files when the app's container
    /// moves, as it can on iOS when the app updates.
    func portable(_ json: JSONRepresentation, id: UUID) -> JSONRepresentation {
        let folder = assetFolder(id: id).absoluteString
        return json.mappingTopLevelStrings { $0.hasPrefix(folder) ? Self.assetScheme + $0.dropFirst(folder.count) : nil }
    }

    /// `json`, as the table stores it, with each file named by ``portable(_:id:)`` pointing
    /// into the row's folder again.
    func resolved(_ json: JSONRepresentation, id: UUID) -> JSONRepresentation {
        let folder = assetFolder(id: id)
        return json.mappingTopLevelStrings { text in
            text.hasPrefix(Self.assetScheme) ? folder.appendingPathComponent(String(text.dropFirst(Self.assetScheme.count))).absoluteString : nil
        }
    }

    /// The prefix of a file name relative to its row's folder, as the table stores it.
    private static let assetScheme = "versioning-asset:"
}

extension Mirror {
    /// Each stored property's name and value, a property wrapper's under the property's own
    /// name rather than its storage's, which adds an underscore.
    var properties: [(name: String, value: Any)] {
        children.compactMap { child in
            child.label.map { (name: $0.hasPrefix("_") ? String($0.dropFirst()) : $0, value: child.value) }
        }
    }
}

private extension JSONRepresentation {
    /// This object with the value at each key of `values` replaced.
    func replacing(_ values: [String: JSONRepresentation]) -> JSONRepresentation {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs.map { (key: $0.key, value: values[$0.key] ?? $0.value) })
    }

    /// This object with each top-level string that `transform` returns a value for replaced by it.
    func mappingTopLevelStrings(_ transform: (String) -> String?) -> JSONRepresentation {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs.map { pair in
            guard case .string(let text) = pair.value, let mapped = transform(text) else { return pair }
            return (key: pair.key, value: .string(mapped))
        })
    }

    /// Every string in this value, at any depth.
    var strings: [String] {
        switch self {
        case .string(let text): [text]
        case .array(let elements): elements.flatMap(\.strings)
        case .object(let pairs): pairs.flatMap { $0.value.strings }
        default: []
        }
    }
}

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

    /// Removes each file in the row's folder that none of `base`, `ours` and `theirs`
    /// points at, and the folder once nothing is left in it.
    func removeUnusedAssets(of row: Row) {
        let folder = assetFolder(id: row.id)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let used = Set([row.base, row.ours, row.theirs].compactMap { $0 }.flatMap(\.strings).compactMap { text in
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
        for child in Mirror(reflecting: record).children {
            guard let label = child.label, let file = (child.value as? any AnyAsset)?.projectedValue else { continue }
            // A property wrapper's storage is the property's name after an underscore.
            files[label.hasPrefix("_") ? String(label.dropFirst()) : label] = file
        }
        return files
    }
}

private extension JSONRepresentation {
    /// This object with the value at each key of `values` replaced.
    func replacing(_ values: [String: JSONRepresentation]) -> JSONRepresentation {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs.map { (key: $0.key, value: values[$0.key] ?? $0.value) })
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

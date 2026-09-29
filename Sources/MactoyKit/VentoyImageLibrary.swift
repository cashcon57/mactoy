import Foundation

/// Locates boot images without treating unrelated files on the USB as images.
public enum VentoyImageLibrary {
    public static func imageDirectory(on volume: URL) -> URL {
        let root = volume.resolvingSymlinksInPath().standardizedFileURL
        // Prefer Ventoy's standard config location; accept a root-level config too.
        for path in ["ventoy/ventoy.json", "ventoy.json"] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(path)),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let controls = config["control"] as? [[String: String]],
                  let searchRoot = controls.compactMap({ $0["VTOY_DEFAULT_SEARCH_ROOT"] }).first,
                  !searchRoot.isEmpty else { continue }
            let relative = searchRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let candidate = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
            // Never let a config redirect file management outside the selected volume.
            if (candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")),
               (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return candidate
            }
        }
        let images = root.appendingPathComponent("images").resolvingSymlinksInPath().standardizedFileURL
        if images.path.hasPrefix(root.path + "/"),
           (try? images.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return images
        }
        return root
    }

    public static func images(on volume: URL) -> [URL] {
        let directory = imageDirectory(on: volume)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let extensions: Set<String> = ["iso", "img", "wim", "efi", "vhd", "vhdx"]
        return enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return url
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

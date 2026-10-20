import Foundation

/// Bobcorn used to be called Matinee. The first launch under the new name
/// brings over the old app's settings and sources, its library and its cache.
enum Migration {
    static func fromMatinee() {
        let debug = Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true
        if let id = Bundle.main.bundleIdentifier, id.contains("Bobcorn") {
            let old = id.replacingOccurrences(of: "Bobcorn", with: "Matinee")
            let defaults = UserDefaults.standard
            if defaults.persistentDomain(forName: id)?.isEmpty ?? true, let previous = defaults.persistentDomain(forName: old) {
                defaults.setPersistentDomain(previous, forName: id)
            }
        }
        let fm = FileManager.default
        let folders: [(FileManager.SearchPathDirectory, String, String)] = [
            (.applicationSupportDirectory, debug ? "Matinee Debug" : "Matinee", debug ? "Bobcorn Debug" : "Bobcorn"),
            (.cachesDirectory, "Matinee", "Bobcorn"),
        ]
        for (place, old, new) in folders {
            let base = fm.urls(for: place, in: .userDomainMask)[0]
            let from = base.appendingPathComponent(old, isDirectory: true)
            let to = base.appendingPathComponent(new, isDirectory: true)
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
    }
}

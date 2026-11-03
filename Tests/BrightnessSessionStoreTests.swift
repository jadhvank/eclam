import Foundation

@main
enum BrightnessSessionStoreTests {
    static func main() throws {
        var passed = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            passed += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eclam-journal-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrightnessSessionStore(fileURL: directory.appendingPathComponent("brightness-session.json"))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let uuid = "6BE485B7-81DA-4AE0-9E06-68E12F936936"
        let snapshot = BrightnessSnapshot(displayUUID: uuid, original: 0.7, lastApplied: 0, capturedAt: now)
        check(try store.load() == nil, "Missing file is an empty session")
        try store.save(snapshot)
        check(try store.load() == snapshot, "Journal round-trips exactly")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Journal permissions are 0600")
        let replacement = BrightnessSnapshot(displayUUID: uuid, original: 0.8, lastApplied: 0.1, capturedAt: now)
        try store.save(replacement)
        check(try store.load() == replacement, "Atomic replacement returns the complete new snapshot")
        check(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["brightness-session.json"],
              "Atomic write leaves no temporary files")
        let validData = try Data(contentsOf: store.fileURL)
        var object = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        object["version"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
        do { _ = try store.load(); fatalError("Unsupported schema accepted") }
        catch BrightnessSessionStore.StoreError.invalidJournal { passed += 1 }
        for invalidField in ["displayUUID", "original", "lastApplied"] {
            var invalid = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
            var fields = invalid["snapshot"] as! [String: Any]
            fields[invalidField] = invalidField == "displayUUID" ? "bad-panel" : 1.1
            invalid["snapshot"] = fields
            try JSONSerialization.data(withJSONObject: invalid).write(to: store.fileURL)
            do { _ = try store.load(); fatalError("Malformed snapshot loaded") }
            catch BrightnessSessionStore.StoreError.invalidJournal { passed += 1 }
        }
        try Data("not json".utf8).write(to: store.fileURL)
        do { _ = try store.load(); fatalError("Invalid JSON accepted") }
        catch BrightnessSessionStore.StoreError.invalidJournal { passed += 1 }
        try Data(repeating: 32, count: 16_385).write(to: store.fileURL)
        do { _ = try store.load(); fatalError("Oversized journal accepted") }
        catch BrightnessSessionStore.StoreError.invalidJournal { passed += 1 }
        check(snapshot.isValid(at: now), "Fresh snapshot is valid")
        check(snapshot.isValid(at: now.addingTimeInterval(86_400)), "Exactly 24 hours is allowed")
        check(!snapshot.isValid(at: now.addingTimeInterval(86_401)), "Expired snapshot is rejected")
        check(!snapshot.isValid(at: now.addingTimeInterval(-1)), "Future capture is rejected")
        for invalid in [Float.nan, .infinity, -0.1, 1.1] {
            let item = BrightnessSnapshot(displayUUID: uuid, original: invalid, lastApplied: 0, capturedAt: now)
            check(!item.isValid(at: now), "Invalid original brightness rejected")
            do { try store.save(item); fatalError("Invalid original persisted") }
            catch BrightnessSessionStore.StoreError.invalidJournal { passed += 1 }
            check(!BrightnessSnapshot(displayUUID: uuid, original: 0.7, lastApplied: invalid,
                                      capturedAt: now).isValid(at: now), "Invalid applied brightness rejected")
        }
        for invalid in ["", "panel-1", "   "] {
            check(!BrightnessSnapshot(displayUUID: invalid, original: 0.7, lastApplied: 0,
                                      capturedAt: now).isValid(at: now), "Malformed panel UUID rejected")
        }
        check(snapshot.matchesPanel(uuid.lowercased()), "UUID case does not change physical identity")
        check(!BrightnessSnapshot(displayUUID: uuid, original: 0.7, lastApplied: 0,
                                  capturedAt: Date(timeIntervalSince1970: .infinity)).isValid(at: now),
              "Nonfinite capture time rejected")
        try store.clear(); try store.clear()
        check(try store.load() == nil, "Clear is idempotent")
        print("BrightnessSessionStore tests: \(passed) passed")
    }
}

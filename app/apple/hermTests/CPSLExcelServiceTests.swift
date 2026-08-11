import Foundation
import Testing
@testable import herm

/// Real cells_xlsx path tests: create → set → write → re-open → read-back
/// through the shipped CPSLExcelService host bridge (not a re-implementation).
struct CPSLExcelServiceTests {
    @Test func createSetWriteReopenReadBack() throws {
        let service = CPSLExcelService()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-cells-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outPath = dir.appendingPathComponent("roundtrip.xlsx").path

        let created = try decode(service.handleJSON(#"{"command":"create"}"#))
        #expect(created["ok"] as? Bool == true)
        let workbook = try requireString(created, "workbook")

        let setString = try decode(service.handleJSON("""
        {"command":"set_string","workbook":"\(workbook)","sheet":0,"col":0,"row":0,"value":"hello"}
        """))
        #expect(setString["ok"] as? Bool == true)

        let setNumber = try decode(service.handleJSON("""
        {"command":"set_number","workbook":"\(workbook)","sheet":0,"col":1,"row":0,"value":42.5}
        """))
        #expect(setNumber["ok"] as? Bool == true)

        let written = try decode(service.handleJSON("""
        {"command":"write","workbook":"\(workbook)","path":\(jsonString(outPath))}
        """))
        #expect(written["ok"] as? Bool == true, "write failed: \(written)")
        #expect(FileManager.default.fileExists(atPath: outPath))

        _ = try decode(service.handleJSON("""
        {"command":"close","workbook":"\(workbook)"}
        """))

        let reopened = try decode(service.handleJSON("""
        {"command":"open","path":\(jsonString(outPath))}
        """))
        #expect(reopened["ok"] as? Bool == true, "re-open failed: \(reopened)")
        let wb2 = try requireString(reopened, "workbook")

        let stringCell = try decode(service.handleJSON("""
        {"command":"get_string","workbook":"\(wb2)","sheet":0,"col":0,"row":0}
        """))
        #expect(stringCell["ok"] as? Bool == true)
        #expect(stringCell["value"] as? String == "hello")

        let numberCell = try decode(service.handleJSON("""
        {"command":"get_number","workbook":"\(wb2)","sheet":0,"col":1,"row":0}
        """))
        #expect(numberCell["ok"] as? Bool == true)
        let number = numberCell["value"] as? Double ?? (numberCell["value"] as? NSNumber)?.doubleValue
        #expect(number == 42.5)

        _ = try decode(service.handleJSON("""
        {"command":"close","workbook":"\(wb2)"}
        """))
    }

    @Test func openInvalidPathReturnsError() throws {
        let service = CPSLExcelService()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-cells-xlsx-missing-\(UUID().uuidString).xlsx")
            .path
        let opened = try decode(service.handleJSON("""
        {"command":"open","path":\(jsonString(missing))}
        """))
        #expect(opened["ok"] as? Bool == false)
        let error = opened["error"] as? String ?? ""
        #expect(!error.isEmpty)
    }

    private func decode(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TestError("invalid json: \(json)")
        }
        return object
    }

    private func requireString(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw TestError("missing \(key) in \(object)")
        }
        return value
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

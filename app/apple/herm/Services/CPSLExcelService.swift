import Foundation

#if canImport(CellsXlsx)
import CellsXlsx
#endif

/// Host bridge for the Luau `xlsx` module. Owns workbook handles and calls the
/// cells `cells_xlsx` C ABI for open/create/read/set/write.
final class CPSLExcelService: @unchecked Sendable {
    private let lock = NSLock()
    private var workbooks: [String: OpaquePointer] = [:]
    private var nextID: UInt64 = 1

    deinit {
        lock.lock()
        let handles = Array(workbooks.values)
        workbooks.removeAll()
        lock.unlock()
        for handle in handles {
            Self.closeHandle(handle)
        }
    }

    /// JSON host-gateway entry point used by CPSL FFI callbacks.
    func handleJSON(_ requestJSON: String) -> String {
        do {
            guard let data = requestJSON.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["command"] as? String
            else {
                return Self.errorJSON("xlsx: invalid request JSON")
            }
            return try dispatch(command: command, object: object)
        } catch {
            return Self.errorJSON("xlsx: \(error.localizedDescription)")
        }
    }

    private func dispatch(command: String, object: [String: Any]) throws -> String {
#if canImport(CellsXlsx)
        switch command {
        case "create":
            guard let wb = cells_xlsx_create() else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "create failed"))
            }
            let id = store(wb)
            return Self.successJSON(["workbook": id])

        case "open":
            guard let path = object["path"] as? String, !path.isEmpty else {
                return Self.errorJSON("xlsx.open: missing path")
            }
            let wb = path.withCString { cells_xlsx_open($0) }
            guard let wb else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "open failed"))
            }
            let id = store(wb)
            return Self.successJSON(["workbook": id])

        case "close":
            let id = try workbookID(object)
            if let handle = take(id) {
                Self.closeHandle(handle)
            }
            return Self.successJSON([:])

        case "sheet_count":
            let handle = try handle(for: object)
            let count = cells_xlsx_sheet_count(handle)
            guard count >= 0 else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "sheet_count failed"))
            }
            return Self.successJSON(["count": count])

        case "sheet_name":
            let handle = try handle(for: object)
            let sheet = try intField(object, "sheet")
            var buffer = [CChar](repeating: 0, count: 512)
            let written = buffer.withUnsafeMutableBufferPointer { buf in
                cells_xlsx_sheet_name(handle, Int32(sheet), buf.baseAddress, buf.count)
            }
            guard written >= 0 else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "sheet_name failed"))
            }
            let name = String(cString: buffer)
            return Self.successJSON(["name": name])

        case "sheets":
            let handle = try handle(for: object)
            let count = cells_xlsx_sheet_count(handle)
            guard count >= 0 else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "sheets failed"))
            }
            var names: [String] = []
            names.reserveCapacity(Int(count))
            for index in 0..<count {
                var buffer = [CChar](repeating: 0, count: 512)
                let written = buffer.withUnsafeMutableBufferPointer { buf in
                    cells_xlsx_sheet_name(handle, index, buf.baseAddress, buf.count)
                }
                guard written >= 0 else {
                    return Self.errorJSON(Self.lastErrorMessage(fallback: "sheets failed"))
                }
                names.append(String(cString: buffer))
            }
            return Self.successJSON(["sheets": names])

        case "get_type":
            let handle = try handle(for: object)
            let sheet = try intField(object, "sheet")
            let col = try intField(object, "col")
            let row = try intField(object, "row")
            let typeCode = cells_xlsx_get_type(handle, Int32(sheet), Int32(col), Int32(row))
            return Self.successJSON(["type": Self.typeName(typeCode)])

        case "get_number":
            let handle = try handle(for: object)
            let sheet = try intField(object, "sheet")
            let col = try intField(object, "col")
            let row = try intField(object, "row")
            let value = cells_xlsx_get_number(handle, Int32(sheet), Int32(col), Int32(row))
            return Self.successJSON(["value": value])

        case "get_string":
            let handle = try handle(for: object)
            let sheet = try intField(object, "sheet")
            let col = try intField(object, "col")
            let row = try intField(object, "row")
            guard let cString = cells_xlsx_get_string(handle, Int32(sheet), Int32(col), Int32(row)) else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "get_string failed"))
            }
            return Self.successJSON(["value": String(cString: cString)])

        case "get_bool":
            let handle = try handle(for: object)
            let sheet = try intField(object, "sheet")
            let col = try intField(object, "col")
            let row = try intField(object, "row")
            let value = cells_xlsx_get_bool(handle, Int32(sheet), Int32(col), Int32(row)) != 0
            return Self.successJSON(["value": value])

        case "get":
            let handle = try handle(for: object)
            let sheet = try intField(object, "sheet")
            let col = try intField(object, "col")
            let row = try intField(object, "row")
            let typeCode = cells_xlsx_get_type(handle, Int32(sheet), Int32(col), Int32(row))
            let typeName = Self.typeName(typeCode)
            let value: Any
            // CellsXlsxValueType: EMPTY=0, NUMBER=1, STRING=2, BOOL=3, OTHER=4
            switch typeCode {
            case 1:
                value = cells_xlsx_get_number(handle, Int32(sheet), Int32(col), Int32(row))
            case 2:
                if let cString = cells_xlsx_get_string(handle, Int32(sheet), Int32(col), Int32(row)) {
                    value = String(cString: cString)
                } else {
                    value = NSNull()
                }
            case 3:
                value = cells_xlsx_get_bool(handle, Int32(sheet), Int32(col), Int32(row)) != 0
            default:
                value = NSNull()
            }
            return Self.successJSON(["type": typeName, "value": value])

        case "set_number":
            let handle = try handle(for: object)
            let sheet = try intField(object, "sheet")
            let col = try intField(object, "col")
            let row = try intField(object, "row")
            let value = try doubleField(object, "value")
            guard cells_xlsx_set_number(handle, Int32(sheet), Int32(col), Int32(row), value) == 0 else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "set_number failed"))
            }
            return Self.successJSON([:])

        case "set_string":
            let handle = try handle(for: object)
            let sheet = try intField(object, "sheet")
            let col = try intField(object, "col")
            let row = try intField(object, "row")
            guard let value = object["value"] as? String else {
                return Self.errorJSON("xlsx.set_string: value must be a string")
            }
            let rc = value.withCString {
                cells_xlsx_set_string(handle, Int32(sheet), Int32(col), Int32(row), $0)
            }
            guard rc == 0 else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "set_string failed"))
            }
            return Self.successJSON([:])

        case "set_bool":
            let handle = try handle(for: object)
            let sheet = try intField(object, "sheet")
            let col = try intField(object, "col")
            let row = try intField(object, "row")
            guard let value = object["value"] as? Bool else {
                return Self.errorJSON("xlsx.set_bool: value must be a boolean")
            }
            guard cells_xlsx_set_bool(handle, Int32(sheet), Int32(col), Int32(row), value ? 1 : 0) == 0 else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "set_bool failed"))
            }
            return Self.successJSON([:])

        case "write":
            let handle = try handle(for: object)
            guard let path = object["path"] as? String, !path.isEmpty else {
                return Self.errorJSON("xlsx.write: missing path")
            }
            let rc = path.withCString { cells_xlsx_write(handle, $0) }
            guard rc == 0 else {
                return Self.errorJSON(Self.lastErrorMessage(fallback: "write failed"))
            }
            return Self.successJSON([:])

        default:
            return Self.errorJSON("xlsx: unsupported command \(command)")
        }
#else
        return Self.errorJSON("xlsx: cells_xlsx library was not linked into this build")
#endif
    }

    // MARK: - Handle bookkeeping

    private func store(_ handle: OpaquePointer) -> String {
        lock.lock()
        defer { lock.unlock() }
        let id = "wb\(nextID)"
        nextID += 1
        workbooks[id] = handle
        return id
    }

    private func handle(for object: [String: Any]) throws -> OpaquePointer {
        let id = try workbookID(object)
        lock.lock()
        defer { lock.unlock() }
        guard let handle = workbooks[id] else {
            throw ExcelServiceError.message("xlsx: invalid workbook handle")
        }
        return handle
    }

    private func take(_ id: String) -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return workbooks.removeValue(forKey: id)
    }

    private static func closeHandle(_ handle: OpaquePointer) {
#if canImport(CellsXlsx)
        cells_xlsx_close(handle)
#endif
    }

    private func workbookID(_ object: [String: Any]) throws -> String {
        guard let id = object["workbook"] as? String, !id.isEmpty else {
            throw ExcelServiceError.message("xlsx: missing workbook")
        }
        return id
    }

    private func intField(_ object: [String: Any], _ key: String) throws -> Int {
        if let value = object[key] as? Int {
            return value
        }
        if let value = object[key] as? NSNumber {
            return value.intValue
        }
        throw ExcelServiceError.message("xlsx: missing or invalid \(key)")
    }

    private func doubleField(_ object: [String: Any], _ key: String) throws -> Double {
        if let value = object[key] as? Double {
            return value
        }
        if let value = object[key] as? Int {
            return Double(value)
        }
        if let value = object[key] as? NSNumber {
            return value.doubleValue
        }
        throw ExcelServiceError.message("xlsx: missing or invalid \(key)")
    }

    private static func typeName(_ code: Int32) -> String {
        // Keep numeric cases so this compiles whether CellsXlsx is imported as
        // a C module with enum macros or as typed Swift enums.
        switch code {
        case 0: return "empty"
        case 1: return "number"
        case 2: return "string"
        case 3: return "bool"
        default: return "other"
        }
    }

    private static func lastErrorMessage(fallback: String) -> String {
#if canImport(CellsXlsx)
        if let cString = cells_xlsx_last_error() {
            let message = String(cString: cString)
            if !message.isEmpty {
                return message
            }
        }
#endif
        return fallback
    }

    static func successJSON(_ payload: [String: Any]) -> String {
        var body = payload
        body["ok"] = true
        return encode(body)
    }

    static func errorJSON(_ message: String) -> String {
        encode(["ok": false, "error": message])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"xlsx json encode failed"}"#
        }
        return string
    }
}

private enum ExcelServiceError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

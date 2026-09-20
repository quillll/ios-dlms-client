//
//  ObisImporter.swift
//  从 JSON / CSV / 预置导入 OBIS 条目。
//
//  JSON 格式：数组，每项 { "code","name","unit","objectClass","attribute" }。
//  CSV 格式：code,name,unit（逗号分隔，支持引号包裹）。
//

import Foundation

enum ObisImporter {
    static func importResult(from url: URL) throws -> [ObisItem] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return try parseJSON(trimmed)
        } else {
            return try parseCSV(trimmed)
        }
    }

    private static func parseJSON(_ text: String) throws -> [ObisItem] {
        guard let data = text.data(using: .utf8) else { throw ImporterError.decode }
        let arr = try JSONDecoder().decode([ImportEntry].self, from: data)
        return arr.compactMap { $0.toItem() }
    }

    private static func parseCSV(_ text: String) throws -> [ObisItem] {
        var rows: [[String]] = []
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines {
            let clean = String(line).trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }
            rows.append(parseBare(line: clean, delim: ","))
        }
        guard rows.count > 0 else { throw ImporterError.empty }

        // 去掉表头（若首行含非数字 code）。
        var body = rows
        if let first = rows.first, first.count >= 1,
           Int(first[0]) == nil && first[0].contains(".") == false {
            body = Array(rows.dropFirst())
        }
        return body.compactMap { fields -> ObisItem? in
            guard fields.count >= 1 else { return nil }
            let code = fields[0].trimmingCharacters(in: .whitespaces)
            let name = fields.count > 1 ? fields[1] : code
            let unit = fields.count > 2 ? fields[2] : ""
            return makeItem(code: code, name: name, unit: unit)
        }
    }

    private static func parseBare(line: String, delim: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == delim && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }

    private static func makeItem(code: String, name: String, unit: String) -> ObisItem? {
        guard isValid(code: code) else { return nil }
        return ObisItem(code: normalize(code), name: name.isEmpty ? code : name,
                        unit: unit, objectClass: 3, attribute: 2, enabled: true)
    }

    /// 校验 6 段 OBIS："1.0.1.8.0.255" 或 IEC "1-0:1.8.0*255"。
    static func isValid(code: String) -> Bool {
        let normalized = normalize(code)
        let parts = normalized.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 6
    }

    /// 统一成点分格式："1-0:1.8.0*255" -> "1.0.1.8.0.255"。
    static func normalize(_ code: String) -> String {
        var s = code
        s = s.replacingOccurrences(of: "-", with: ".")
        s = s.replacingOccurrences(of: ":", with: ".")
        s = s.replacingOccurrences(of: "*", with: ".")
        return s.split(separator: ".").map(String.init).joined(separator: ".")
    }
}

private struct ImportEntry: Decodable {
    var code: String
    var name: String?
    var unit: String?
    var objectClass: Int?
    var attribute: Int?

    func toItem() -> ObisItem? {
        guard ObisImporter.isValid(code: code) else { return nil }
        return ObisItem(
            code: ObisImporter.normalize(code),
            name: name ?? ObisImporter.normalize(code),
            unit: unit ?? "",
            objectClass: objectClass ?? 3,
            attribute: attribute ?? 2,
            enabled: true)
    }
}

enum ImporterError: LocalizedError {
    case decode
    case empty
    var errorDescription: String? {
        switch self {
        case .decode: return "文件无法解析"
        case .empty: return "文件为空或没有有效 OBIS"
        }
    }
}
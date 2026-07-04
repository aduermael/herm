import Foundation

nonisolated struct CPSLAgentSkill: Equatable, Sendable {
    let name: String
    let description: String
    let path: String
    let virtualName: String
}

nonisolated struct CPSLSystemSkillMount: Equatable, Sendable {
    let hostURL: URL
    let virtualPath: String
}

nonisolated enum CPSLSkillCatalog {
    static let skillFileName = "SKILL.md"
    static let virtualRoot = "/skills"

    static func availableSkills(
        userRootURL: URL?,
        bundle: Bundle = .main
    ) -> [CPSLAgentSkill] {
        var byName: [String: CPSLAgentSkill] = [:]
        for skill in userSkills(userRootURL: userRootURL) {
            byName[skill.name.lowercased()] = skill
        }
        for skill in systemSkills(bundle: bundle) {
            byName[skill.name.lowercased()] = skill
        }
        return byName.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func systemSkillMounts(bundle: Bundle = .main) -> [CPSLSystemSkillMount] {
        guard let rootURL = bundledSkillsRootURL(bundle: bundle) else {
            return []
        }
        return skillEntries(in: rootURL).compactMap { entry in
            guard entry.isDirectory,
                    let skill = parseSkill(
                        fileURL: entry.skillFileURL,
                        defaultName: entry.defaultName,
                        virtualName: entry.virtualName,
                        path: skillVirtualFilePath(entry)
                    )
            else {
                return nil
            }
            return CPSLSystemSkillMount(
                hostURL: entry.url,
                virtualPath: "\(virtualRoot)/\(skill.virtualName)"
            )
        }
    }

    private static func systemSkills(bundle: Bundle) -> [CPSLAgentSkill] {
        guard let rootURL = bundledSkillsRootURL(bundle: bundle) else {
            return []
        }
        return skills(in: rootURL, allowsFlatFiles: false)
    }

    private static func userSkills(userRootURL: URL?) -> [CPSLAgentSkill] {
        guard let userRootURL else {
            return []
        }
        return skills(in: userRootURL, allowsFlatFiles: true)
    }

    private static func skills(in rootURL: URL, allowsFlatFiles: Bool) -> [CPSLAgentSkill] {
        skillEntries(in: rootURL, allowsFlatFiles: allowsFlatFiles).compactMap { entry in
            parseSkill(
                fileURL: entry.skillFileURL,
                defaultName: entry.defaultName,
                virtualName: entry.virtualName,
                path: skillVirtualFilePath(entry)
            )
        }
    }

    private static func bundledSkillsRootURL(bundle: Bundle) -> URL? {
        let candidates = [
            bundle.url(forResource: "Skills", withExtension: nil),
            bundle.resourceURL?.appendingPathComponent("Skills", isDirectory: true),
            bundle.bundleURL.appendingPathComponent("Skills", isDirectory: true)
        ].compactMap { $0 }

        return candidates.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private static func skillEntries(in rootURL: URL, allowsFlatFiles: Bool = true) -> [CPSLSkillEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            let virtualName = sanitizedSkillPathName(
                isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            )
            if isDirectory {
                let skillFileURL = url.appendingPathComponent(skillFileName, isDirectory: false)
                guard FileManager.default.fileExists(atPath: skillFileURL.path) else {
                    return nil
                }
                return CPSLSkillEntry(
                    url: url,
                    skillFileURL: skillFileURL,
                    defaultName: url.lastPathComponent,
                    virtualName: virtualName,
                    isDirectory: true
                )
            }
            guard allowsFlatFiles, url.pathExtension.lowercased() == "md" else {
                return nil
            }
            return CPSLSkillEntry(
                url: url,
                skillFileURL: url,
                defaultName: url.deletingPathExtension().lastPathComponent,
                virtualName: virtualName,
                isDirectory: false
            )
        }
    }

    private static func skillVirtualFilePath(_ entry: CPSLSkillEntry) -> String {
        if entry.isDirectory {
            return "\(virtualRoot)/\(entry.virtualName)/\(skillFileName)"
        }
        return "\(virtualRoot)/\(entry.virtualName).md"
    }

    private static func parseSkill(
        fileURL: URL,
        defaultName: String,
        virtualName: String,
        path: String
    ) -> CPSLAgentSkill? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8),
                let frontMatter = markdownFrontMatter(raw)
        else {
            return nil
        }
        let values = parseFrontMatter(frontMatter)
        let name = (values["name"] ?? defaultName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return nil
        }
        let description = shortDescription(
            values["metadata.short-description"]
                ?? values["description"]
                ?? values["when_to_use"]
                ?? ""
        )
        return CPSLAgentSkill(
            name: name,
            description: description,
            path: path,
            virtualName: virtualName
        )
    }

    private static func markdownFrontMatter(_ raw: String) -> String? {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard !lines.isEmpty else {
            return nil
        }
        lines[0] = lines[0].replacingOccurrences(of: "\u{FEFF}", with: "")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }
        var frontMatter: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                return frontMatter.joined(separator: "\n")
            }
            frontMatter.append(line)
        }
        return nil
    }

    private static func parseFrontMatter(_ frontMatter: String) -> [String: String] {
        let lines = frontMatter.components(separatedBy: "\n")
        var values: [String: String] = [:]
        var index = 0
        var inMetadata = false

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { index += 1 }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inMetadata = false
            }
            if trimmed == "metadata:" {
                inMetadata = true
                continue
            }
            guard let separator = trimmed.firstIndex(of: ":") else {
                continue
            }

            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStart = trimmed.index(after: separator)
            let rawValue = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fullKey = inMetadata ? "metadata.\(key)" : key
            if rawValue == "|" || rawValue == ">" {
                values[fullKey] = foldedBlock(lines: lines, startIndex: index + 1)
            } else {
                values[fullKey] = unquoted(rawValue)
            }
        }
        return values
    }

    private static func foldedBlock(lines: [String], startIndex: Int) -> String {
        var block: [String] = []
        for line in lines.dropFirst(startIndex) {
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && line.contains(":") {
                break
            }
            block.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return block.joined(separator: "\n")
    }

    private static func unquoted(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
                let first = value.first,
                let last = value.last,
                (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private static func shortDescription(_ value: String) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > 260 else {
            return collapsed
        }
        return "\(collapsed.prefix(257))..."
    }

    private static func sanitizedSkillPathName(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-" {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("-")
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return trimmed.isEmpty ? "skill" : trimmed
    }
}

private nonisolated struct CPSLSkillEntry {
    let url: URL
    let skillFileURL: URL
    let defaultName: String
    let virtualName: String
    let isDirectory: Bool
}

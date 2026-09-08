import Foundation

/// 往 harness 的配置文件里增删 brosis 这一项（D33）。
///
/// **全是纯函数**：输入原文本 + 目标状态，输出新文本。不碰磁盘，所以自检可以把每种格式、
/// 每种边界（空文件、已有别的服务器、已有同名项、坏文件）都跑一遍而不动任何真实配置。
///
/// 两条硬规矩：
///  1. **只动 `brosis` 这一项**，别人的服务器一个字节都不改；
///  2. **解析不了就抛错**，绝不"猜着写"——上层据此改成"复制这段手动加"。
///
/// TOML 走逐行手术（原文完全保留，连注释和空行都不动）；JSON 只能解析后重写，
/// 会重排键序、统一缩进——所以写之前一律先备份（`MCPIntegration` 负责）。
enum MCPConfigError: Error, CustomStringConvertible {
    case unparsable(String)
    var description: String {
        switch self {
        case .unparsable(let why): "配置文件解析不了：\(why)"
        }
    }
}

enum MCPConfigWriter {

    struct Entry: Sendable {
        var name: String
        var command: String
        var args: [String] = []
        var env: [String: String] = [:]
        /// Claude Code 的条目里有 `type: "stdio"`；其余家没有也不影响。
        var includeStdioType: Bool = false
    }

    /// 目标状态与现状一致时返回 nil（调用方据此"什么都不写"）。
    static func apply(format: HarnessFormat, text: String,
                      entry: Entry, enabled: Bool) throws -> String? {
        switch format {
        case .mcpServersJSON:  try applyJSON(text: text, path: ["mcpServers"], entry: entry, enabled: enabled)
        case .zcodeNestedJSON: try applyJSON(text: text, path: ["mcp", "servers"], entry: entry, enabled: enabled)
        case .mcpServersTOML:  applyTOML(text: text, entry: entry, enabled: enabled)
        }
    }

    /// 现在这份配置里 brosis 指向哪个可执行文件。nil = 没有这一项。
    static func currentCommand(format: HarnessFormat, text: String, name: String) throws -> String? {
        switch format {
        case .mcpServersJSON:  try jsonCommand(text: text, path: ["mcpServers"], name: name)
        case .zcodeNestedJSON: try jsonCommand(text: text, path: ["mcp", "servers"], name: name)
        case .mcpServersTOML:  tomlCommand(text: text, name: name)
        }
    }

    // MARK: - JSON

    private static func parse(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw MCPConfigError.unparsable("不是一个 JSON 对象（可能带注释、或者写坏了）")
        }
        return dictionary
    }

    private static func serialize(_ dictionary: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPConfigError.unparsable("序列化失败")
        }
        return text + "\n"
    }

    /// 沿 path 递归写入 / 删除 `name`。中间容器不存在就现建。
    private static func write(_ dictionary: [String: Any], path: [String],
                              name: String, value: [String: Any]?) -> [String: Any] {
        var copy = dictionary
        guard let head = path.first else {
            if let value { copy[name] = value } else { copy.removeValue(forKey: name) }
            return copy
        }
        let child = copy[head] as? [String: Any] ?? [:]
        copy[head] = write(child, path: Array(path.dropFirst()), name: name, value: value)
        return copy
    }

    private static func read(_ dictionary: [String: Any], path: [String]) -> [String: Any] {
        var cursor = dictionary
        for key in path {
            cursor = cursor[key] as? [String: Any] ?? [:]
        }
        return cursor
    }

    private static func applyJSON(text: String, path: [String],
                                  entry: Entry, enabled: Bool) throws -> String? {
        let root = try parse(text)
        let existing = read(root, path: path)[entry.name] as? [String: Any]
        if enabled {
            var value: [String: Any] = ["command": entry.command, "args": entry.args]
            if entry.includeStdioType { value["type"] = "stdio" }
            if !entry.env.isEmpty { value["env"] = entry.env }
            // 已经一模一样就不写（避免每次开面板都改文件、每次都留一份备份）。
            if let existing, NSDictionary(dictionary: existing).isEqual(to: value) { return nil }
            return try serialize(write(root, path: path, name: entry.name, value: value))
        } else {
            guard existing != nil else { return nil }
            return try serialize(write(root, path: path, name: entry.name, value: nil))
        }
    }

    private static func jsonCommand(text: String, path: [String], name: String) throws -> String? {
        let root = try parse(text)
        let node = read(root, path: path)[name] as? [String: Any]
        return node?["command"] as? String
    }

    // MARK: - TOML（逐行手术：原文一个字节都不动，只增删自己那几节）

    /// 属于 `[mcp_servers.<name>]` 或它的子表 `[mcp_servers.<name>.xxx]` 的节头。
    private static func isOurHeader(_ line: String, name: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return false }
        let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        return inner == "mcp_servers.\(name)" || inner.hasPrefix("mcp_servers.\(name).")
    }

    private static func isSectionHeader(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[") && t.hasSuffix("]")
    }

    /// 把属于我们的那几节整段摘掉，返回（其余行, 是否摘到过）。
    private static func stripTOML(_ lines: [String], name: String) -> ([String], Bool) {
        var out: [String] = []
        var dropping = false
        var found = false
        for line in lines {
            if isSectionHeader(line) {
                dropping = isOurHeader(line, name: name)
                if dropping { found = true; continue }
            }
            if !dropping { out.append(line) }
        }
        // 摘完可能在结尾留下多余空行，收一收（只收结尾，不动中间）。
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return (out, found)
    }

    private static func tomlEscape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func applyTOML(text: String, entry: Entry, enabled: Bool) -> String? {
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let (rest, found) = stripTOML(lines, name: entry.name)
        if !enabled {
            guard found else { return nil }
            return rest.isEmpty ? "" : rest.joined(separator: "\n") + "\n"
        }
        var block: [String] = ["[mcp_servers.\(entry.name)]",
                               "command = \(tomlEscape(entry.command))",
                               "args = [\(entry.args.map(tomlEscape).joined(separator: ", "))]"]
        if !entry.env.isEmpty {
            block.append("")
            block.append("[mcp_servers.\(entry.name).env]")
            for key in entry.env.keys.sorted() {
                block.append("\(key) = \(tomlEscape(entry.env[key]!))")
            }
        }
        var out = rest
        if !out.isEmpty { out.append("") }
        out.append(contentsOf: block)
        let result = out.joined(separator: "\n") + "\n"
        return result == text ? nil : result
    }

    private static func tomlCommand(text: String, name: String) -> String? {
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if isSectionHeader(line) {
                let t = line.trimmingCharacters(in: .whitespaces)
                inside = t == "[mcp_servers.\(name)]"
                continue
            }
            guard inside else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "command" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }
}

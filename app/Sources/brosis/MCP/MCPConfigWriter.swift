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

    /// 按描述表造一条 Entry。差异（例如 Claude Code 要 `type: "stdio"`）取自 `Harness` 的字段，
    /// 调用方不再各写一遍 id 判断。
    ///
    /// **`BROSIS_CLIENT_ID` 是这条 Entry 的要害**（2026-09-09）：grants 表按 client_id 发，
    /// 而 client_id 默认取 MCP `initialize` 里客户端自报的 `clientInfo.name`——那是它说了算的，
    /// 各家叫什么只有连过来才知道，对不上就被全拒。面板的「学习模式」本来就是为这件事存在的：
    /// 每 2 秒查一次 `mcp_audit`，人盯着看谁来连。
    ///
    /// 而 `brosis-mcp` 认 `BROSIS_CLIENT_ID` **覆盖**自报名（见 core/Sources/brosis-mcp 的
    /// `Config.clientIDOverride`）。所以只要配置是我们写的，就把名字钉死成 harness id，
    /// 发 grant 用的也是同一个 id——**名字对不上从设计上没有了**，自动集成也就不需要轮询。
    ///
    /// 唯一钉不死的是走官方 CLI 增删的那家（Claude Code）：`claude mcp add` 的 `-e` 是
    /// 变长选项，拼进模板要赌它的解析顺序，而赌输了写坏的是 100 KB 的 `~/.claude.json`。
    /// 不赌——它自报的就是 `claude-code`，与 harness id 本来就相等（本机 grants 表实测）。
    static func entry(for harness: Harness, command: String) -> Entry {
        Entry(name: HarnessCatalog.serverName, command: command,
              env: [Self.clientIDEnvKey: harness.id],
              includeStdioType: harness.entryIncludesStdioType)
    }

    /// `brosis-mcp` 用它覆盖客户端自报的名字。
    static let clientIDEnvKey = "BROSIS_CLIENT_ID"

    /// 目标状态与现状一致时返回 nil（调用方据此"什么都不写"）。
    static func apply(format: HarnessFormat, text: String,
                      entry: Entry, enabled: Bool) throws -> String? {
        switch format {
        case .mcpServersJSON:  try applyJSON(text: text, path: ["mcpServers"], entry: entry, enabled: enabled)
        case .zcodeNestedJSON: try applyJSON(text: text, path: ["mcp", "servers"], entry: entry, enabled: enabled)
        case .mcpServersTOML:  applyTOML(text: text, entry: entry, enabled: enabled)
        }
    }

    /// 现有的 brosis 条目里我们关心的两件事，**一次解析读齐**。
    ///
    /// 曾经是 `currentCommand` 与 `currentClientID` 两个函数，各自一个 `switch` 三个分支、
    /// 各自把同一段文本再解析一遍。除了白跑一趟，真正的代价是"加一种配置格式要改两个
    /// switch 且必须同步"——而这两个 switch 的分支表本来就一模一样。
    struct Existing: Sendable, Equatable {
        /// brosis 指向哪个可执行文件。nil = 配置里没有这一项。
        var command: String?
        /// 条目里钉的 `BROSIS_CLIENT_ID`。nil = 没这一项、或者它没带这个 env。
        var clientID: String?
    }

    static func current(format: HarnessFormat, text: String, name: String) throws -> Existing {
        switch format {
        case .mcpServersJSON:  try jsonCurrent(text: text, path: ["mcpServers"], name: name)
        case .zcodeNestedJSON: try jsonCurrent(text: text, path: ["mcp", "servers"], name: name)
        case .mcpServersTOML:  tomlCurrent(text: text, name: name)
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

    private static func jsonCurrent(text: String, path: [String], name: String) throws -> Existing {
        let node = read(try parse(text), path: path)[name] as? [String: Any]
        return Existing(command: node?["command"] as? String,
                        clientID: (node?["env"] as? [String: Any])?[clientIDEnvKey] as? String)
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

    /// 一趟扫完整份 TOML，把 `[mcp_servers.<name>]` 的 command 与
    /// `[mcp_servers.<name>.env]` 里的 client id 一起带回来。
    /// 反转义只有这一份，command 与 env 共用——两处各写一份的话它们迟早不一样。
    private static func tomlCurrent(text: String, name: String) -> Existing {
        var found = Existing()
        var section = ""
        for line in text.components(separatedBy: "\n") {
            if isSectionHeader(line) {
                let t = line.trimmingCharacters(in: .whitespaces)
                section = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let (key, value) = tomlPair(line) else { continue }
            if section == "mcp_servers.\(name)", key == "command" {
                found.command = found.command ?? value
            } else if section == "mcp_servers.\(name).env", key == clientIDEnvKey {
                found.clientID = found.clientID ?? value
            }
        }
        return found
    }

    /// `key = "value"` → (key, 反转义后的 value)。不是这个形状就返回 nil。
    private static func tomlPair(_ line: String) -> (String, String)? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var value = parts[1].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return (parts[0].trimmingCharacters(in: .whitespaces),
                value.replacingOccurrences(of: "\\\"", with: "\"")
                     .replacingOccurrences(of: "\\\\", with: "\\"))
    }
}

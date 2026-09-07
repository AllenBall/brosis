import Foundation

/// 与 Foundation JSON 对象等价、但 `Sendable` 且 `Codable` 的 JSON 值。
///
/// 为什么不用 `[String: Any]`：本包要在 Swift 6 严格并发下跨线程传递请求 / 响应，
/// `Any` 不是 `Sendable`；而 MCP 的 `tools/call` 参数是任意 JSON，又不能写死成结构体。
///
/// **整数与浮点分开**：`text_versions.id` 之类的 id 必须原样往返，
/// 统一按 `Double` 解会在 2^53 之外丢精度，也会让 `1` 变成 `1.0`（MCP 客户端看着别扭）。
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "不是合法的 JSON 值")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:          try container.encodeNil()
        case .bool(let v):   try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v):  try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

// MARK: - 取值

extension JSONValue {

    public var isNull: Bool { if case .null = self { return true }; return false }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .int(let v):  return v != 0
        default:           return nil
        }
    }

    /// 整数取值。JSON 里写成 `24.0` 的整数也认（客户端语言不一定区分）。
    public var intValue: Int64? {
        switch self {
        case .int(let v):    return v
        case .double(let v): return v.rounded() == v ? Int64(v) : nil
        case .string(let v): return Int64(v)
        default:             return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let v):    return Double(v)
        case .double(let v): return v
        default:             return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }
}

// MARK: - 与 Foundation / Codable 互转

extension JSONValue {

    /// 从 `JSONSerialization` 产出的对象转过来。无法表示的值转成 `.null`。
    public init(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // NSNumber 不区分 Bool 与 0/1，只能看 objCType。
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if let s = String(validatingCString: n.objCType),
                    s == "d" || s == "f" { self = .double(n.doubleValue) }
            else { self = .int(n.int64Value) }
        case let v as String:
            self = .string(v)
        case let v as [Any]:
            self = .array(v.map { JSONValue(foundation: $0) })
        case let v as [String: Any]:
            self = .object(v.mapValues { JSONValue(foundation: $0) })
        default:
            self = .null
        }
    }

    /// 转回 `JSONSerialization` 能吃的对象（CLI 的 `emit` 与 MCP 侧输出用）。
    public var foundationObject: Any {
        switch self {
        case .null:          return NSNull()
        case .bool(let v):   return v
        case .int(let v):    return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v):  return v.map(\.foundationObject)
        case .object(let v): return v.mapValues(\.foundationObject)
        }
    }

    /// 把任意 `Encodable`（core 的检索结果结构体）转成 `JSONValue`。
    /// 键名保持结构体的 camelCase——MCP 客户端拿到的字段名与 `core/README.md` 的 API 一致。
    public init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// 便捷构造：字典字面量里混着 Int / String / Bool 时少写一堆 `.int(...)`。
    public static func of(_ dict: [String: JSONValue]) -> JSONValue { .object(dict) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

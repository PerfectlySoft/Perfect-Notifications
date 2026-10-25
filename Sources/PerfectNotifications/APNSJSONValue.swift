import Foundation

/// A JSON value: the `Sendable` replacement for the `Any` that 5.x's
/// `customPayload(String, Any)` accepted.
///
/// Literals convert directly, so `.customPayload("orderId", "ORD-123")`,
/// `.customPayload("amount", 49)`, `.customPayload("refresh", true)` and
/// `.customPayload("tags", ["a", "b"])` compile as before. Wrap variables explicitly
/// (`.string(orderID)`, `.int(count)`), or convert an existing `JSONSerialization`-style
/// value with ``init(jsonObject:)``.
public enum APNSJSONValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([APNSJSONValue])
    case object([String: APNSJSONValue])

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([APNSJSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: APNSJSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i):    try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Conversion from untyped values

    /// Convert an untyped JSON-compatible value (the kind `JSONSerialization` produces
    /// or 5.x's `customPayload` accepted): `String`, `Bool`, integers, `Double`/`Float`,
    /// `NSNumber`, `NSNull`, `[Any]`, `[String: Any]`, `Optional.none`, or an
    /// `APNSJSONValue`.
    ///
    /// The conversion happens immediately, so the result is genuinely `Sendable`.
    ///
    /// - Throws: ``APNSClientError/invalidJSONValue(_:)`` naming the first unsupported type
    ///   (or a non-finite number).
    public init(jsonObject value: Any) throws {
        self = try Self.convert(value)
    }

    private static func convert(_ value: Any) throws -> APNSJSONValue {
        // Unwrap Optional<Wrapped> boxed in Any.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return .null }
            return try convert(wrapped)
        }
        // Exact native Swift types first: on Darwin `as? NSNumber` would also match
        // these through bridging, and `as? Bool` would match NSNumber(1).
        switch value {
        case let v as APNSJSONValue: return v
        case let v as String: return .string(v)
        case let v as Bool where type(of: value) == Bool.self: return .bool(v)
        case let v as Int where type(of: value) == Int.self: return .int(v)
        case let v as Int64 where type(of: value) == Int64.self:
            guard let i = Int(exactly: v) else { throw APNSClientError.invalidJSONValue("Int64 out of range") }
            return .int(i)
        case let v as Int32 where type(of: value) == Int32.self: return .int(Int(v))
        case let v as UInt where type(of: value) == UInt.self:
            guard let i = Int(exactly: v) else { throw APNSClientError.invalidJSONValue("UInt out of range") }
            return .int(i)
        case let v as Double where type(of: value) == Double.self: return try finite(v)
        case let v as Float where type(of: value) == Float.self: return try finite(Double(v))
        case is NSNull: return .null
        case let n as NSNumber: return try convert(number: n)
        case let a as [Any]: return .array(try a.map(convert))
        case let o as [String: Any]: return .object(try o.mapValues(convert))
        default:
            throw APNSClientError.invalidJSONValue(String(describing: type(of: value)))
        }
    }

    private static func finite(_ d: Double) throws -> APNSJSONValue {
        guard d.isFinite else { throw APNSClientError.invalidJSONValue("non-finite number") }
        return .double(d)
    }

    private static func convert(number n: NSNumber) throws -> APNSJSONValue {
        #if canImport(Darwin)
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        #endif
        switch String(cString: n.objCType) {
        case "c", "B":
            #if canImport(Darwin)
            return .int(n.intValue)   // a real char-typed number, not a CFBoolean
            #else
            return .bool(n.boolValue)
            #endif
        case "f", "d":
            return try finite(n.doubleValue)
        default:
            guard let i = Int(exactly: n.int64Value) else { throw APNSClientError.invalidJSONValue("number out of range") }
            return .int(i)
        }
    }
}

// MARK: - Literals

extension APNSJSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: APNSJSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, APNSJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

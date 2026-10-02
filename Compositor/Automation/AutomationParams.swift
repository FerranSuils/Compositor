import Foundation
import CoreGraphics

/// Errors raised while turning a request into editing work. Each maps to an HTTP status and a message the caller
/// can act on; nothing else leaks out of the session.
nonisolated enum AutomationError: Error, CustomStringConvertible {
    case badRequest(String)
    case notFound(String)
    case conflict(String)
    case unprocessable(String)
    case failed(String)

    var status: Int {
        switch self {
        case .badRequest: return 400
        case .notFound: return 404
        case .conflict: return 409
        case .unprocessable: return 422
        case .failed: return 500
        }
    }

    var description: String {
        switch self {
        case .badRequest(let text), .notFound(let text), .conflict(let text), .unprocessable(let text), .failed(let text):
            return text
        }
    }
}

/// Typed access to one command's parameters. Every getter names the key in its error so a caller sees exactly what
/// was wrong with the payload instead of a generic decode failure.
nonisolated struct AutomationParams {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    func has(_ key: String) -> Bool {
        guard let value = raw[key] else { return false }
        return !(value is NSNull)
    }

    var keys: [String] { Array(raw.keys) }

    // MARK: Scalars

    func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard has(key) else { return nil }
        guard let value = raw[key] as? String else { throw AutomationError.badRequest("\"\(key)\" must be a string") }
        return value
    }

    func string(_ key: String, default value: String) throws -> String { try optionalString(key) ?? value }

    func double(_ key: String) throws -> Double {
        guard let value = try optionalDouble(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard has(key) else { return nil }
        guard let number = raw[key] as? NSNumber, !Self.isBoolean(raw[key]!) else {
            throw AutomationError.badRequest("\"\(key)\" must be a number")
        }
        let value = number.doubleValue
        guard value.isFinite else { throw AutomationError.badRequest("\"\(key)\" must be finite") }
        return value
    }

    func double(_ key: String, default value: Double) throws -> Double { try optionalDouble(key) ?? value }

    /// A number clamped into `range`; values outside are rejected rather than silently clamped, so a script learns
    /// about a typo instead of getting a subtly different picture.
    func double(_ key: String, in range: ClosedRange<Double>, default value: Double? = nil) throws -> Double {
        guard let number = try optionalDouble(key) else {
            if let value { return value }
            throw AutomationError.badRequest("\"\(key)\" is required")
        }
        guard range.contains(number) else {
            throw AutomationError.badRequest("\"\(key)\" must be between \(Self.format(range.lowerBound)) and \(Self.format(range.upperBound))")
        }
        return number
    }

    func int(_ key: String) throws -> Int {
        guard let value = try optionalInt(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = try optionalDouble(key) else { return nil }
        guard value == value.rounded(), abs(value) < 1e12 else { throw AutomationError.badRequest("\"\(key)\" must be an integer") }
        return Int(value)
    }

    func int(_ key: String, default value: Int) throws -> Int { try optionalInt(key) ?? value }

    func int(_ key: String, in range: ClosedRange<Int>, default value: Int? = nil) throws -> Int {
        guard let number = try optionalInt(key) else {
            if let value { return value }
            throw AutomationError.badRequest("\"\(key)\" is required")
        }
        guard range.contains(number) else {
            throw AutomationError.badRequest("\"\(key)\" must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return number
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = try optionalBool(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard has(key) else { return nil }
        if let number = raw[key] as? NSNumber { return number.boolValue }
        if let text = raw[key] as? String {
            switch text.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: break
            }
        }
        throw AutomationError.badRequest("\"\(key)\" must be a boolean")
    }

    func bool(_ key: String, default value: Bool) throws -> Bool { try optionalBool(key) ?? value }

    // MARK: Enumerations

    /// Looks `key` up in `cases`, matching the raw value case-insensitively and ignoring spaces, so
    /// `"linear dodge (add)"`, `"Linear Dodge (Add)"` and `"linearDodge(add)"` all name the same blend mode.
    func enumeration<T: RawRepresentable>(_ key: String, cases: [T], default value: T? = nil) throws -> T where T.RawValue == String {
        guard let text = try optionalString(key) else {
            if let value { return value }
            throw AutomationError.badRequest("\"\(key)\" is required")
        }
        if let match = Self.match(text, in: cases) { return match }
        throw AutomationError.badRequest("\"\(key)\" must be one of: \(cases.map(\.rawValue).joined(separator: ", "))")
    }

    static func match<T: RawRepresentable>(_ text: String, in cases: [T]) -> T? where T.RawValue == String {
        let wanted = normalize(text)
        return cases.first { normalize($0.rawValue) == wanted }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
    }

    // MARK: Structures

    func object(_ key: String) throws -> AutomationParams {
        guard let value = try optionalObject(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalObject(_ key: String) throws -> AutomationParams? {
        guard has(key) else { return nil }
        guard let value = raw[key] as? [String: Any] else { throw AutomationError.badRequest("\"\(key)\" must be an object") }
        return AutomationParams(value)
    }

    func array(_ key: String) throws -> [Any] {
        guard let value = try optionalArray(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalArray(_ key: String) throws -> [Any]? {
        guard has(key) else { return nil }
        guard let value = raw[key] as? [Any] else { throw AutomationError.badRequest("\"\(key)\" must be an array") }
        return value
    }

    func objects(_ key: String) throws -> [AutomationParams] {
        try array(key).enumerated().map { index, element in
            guard let object = element as? [String: Any] else { throw AutomationError.badRequest("\"\(key)[\(index)]\" must be an object") }
            return AutomationParams(object)
        }
    }

    func strings(_ key: String) throws -> [String] {
        try array(key).enumerated().map { index, element in
            guard let text = element as? String else { throw AutomationError.badRequest("\"\(key)[\(index)]\" must be a string") }
            return text
        }
    }

    func optionalStrings(_ key: String) throws -> [String]? { has(key) ? try strings(key) : nil }

    func doubles(_ key: String) throws -> [Double] {
        try array(key).enumerated().map { index, element in
            guard let number = element as? NSNumber, !Self.isBoolean(element), number.doubleValue.isFinite else {
                throw AutomationError.badRequest("\"\(key)[\(index)]\" must be a number")
            }
            return number.doubleValue
        }
    }

    // MARK: Geometry

    /// A point given as `[x, y]` or `{"x":…, "y":…}`.
    func point(_ key: String) throws -> CGPoint {
        guard let value = try optionalPoint(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalPoint(_ key: String) throws -> CGPoint? {
        guard has(key) else { return nil }
        return try Self.point(raw[key]!, named: key)
    }

    static func point(_ value: Any, named key: String) throws -> CGPoint {
        if let list = value as? [Any], list.count == 2, let x = list[0] as? NSNumber, let y = list[1] as? NSNumber {
            return CGPoint(x: x.doubleValue, y: y.doubleValue)
        }
        if let object = value as? [String: Any], let x = object["x"] as? NSNumber, let y = object["y"] as? NSNumber {
            return CGPoint(x: x.doubleValue, y: y.doubleValue)
        }
        throw AutomationError.badRequest("\"\(key)\" must be a point: [x, y] or {\"x\": …, \"y\": …}")
    }

    func points(_ key: String) throws -> [CGPoint] {
        try array(key).enumerated().map { try Self.point($1, named: "\(key)[\($0)]") }
    }

    /// A size given as `[width, height]` or `{"width":…, "height":…}`.
    func size(_ key: String) throws -> CGSize {
        guard let value = try optionalSize(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalSize(_ key: String) throws -> CGSize? {
        guard has(key) else { return nil }
        let value = raw[key]!
        if let list = value as? [Any], list.count == 2, let w = list[0] as? NSNumber, let h = list[1] as? NSNumber {
            return CGSize(width: w.doubleValue, height: h.doubleValue)
        }
        if let object = value as? [String: Any], let w = object["width"] as? NSNumber, let h = object["height"] as? NSNumber {
            return CGSize(width: w.doubleValue, height: h.doubleValue)
        }
        throw AutomationError.badRequest("\"\(key)\" must be a size: [width, height] or {\"width\": …, \"height\": …}")
    }

    /// A rectangle given as `[x, y, width, height]` or `{"x","y","width","height"}`.
    func rect(_ key: String) throws -> CGRect {
        guard let value = try optionalRect(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalRect(_ key: String) throws -> CGRect? {
        guard has(key) else { return nil }
        let value = raw[key]!
        if let list = value as? [Any], list.count == 4 {
            let numbers = list.compactMap { $0 as? NSNumber }
            if numbers.count == 4 {
                return CGRect(x: numbers[0].doubleValue, y: numbers[1].doubleValue, width: numbers[2].doubleValue, height: numbers[3].doubleValue)
            }
        }
        if let object = value as? [String: Any], let x = object["x"] as? NSNumber, let y = object["y"] as? NSNumber,
           let w = object["width"] as? NSNumber, let h = object["height"] as? NSNumber {
            return CGRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
        }
        throw AutomationError.badRequest("\"\(key)\" must be a rectangle: [x, y, width, height] or {\"x\",\"y\",\"width\",\"height\"}")
    }

    // MARK: Colors

    /// A color as `"#RRGGBB"`, `"#RRGGBBAA"`, `[r, g, b]`, `[r, g, b, a]` (0–1) or `{"red","green","blue","alpha"}` (0–1).
    func color(_ key: String) throws -> AutomationColor {
        guard let value = try optionalColor(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalColor(_ key: String) throws -> AutomationColor? {
        guard has(key) else { return nil }
        guard let color = AutomationColor(any: raw[key]!) else {
            throw AutomationError.badRequest("\"\(key)\" must be a color: \"#RRGGBB\", \"#RRGGBBAA\", [r, g, b(, a)] in 0–1, or {\"red\",\"green\",\"blue\",\"alpha\"}")
        }
        return color
    }

    // MARK: Binary payloads

    /// Base64 data under `key`; a `data:` URL prefix is tolerated.
    func data(_ key: String) throws -> Data {
        guard let value = try optionalData(key) else { throw AutomationError.badRequest("\"\(key)\" is required") }
        return value
    }

    func optionalData(_ key: String) throws -> Data? {
        guard var text = try optionalString(key) else { return nil }
        if text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") { text = String(text[text.index(after: comma)...]) }
        guard let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) else {
            throw AutomationError.badRequest("\"\(key)\" must be base64 data")
        }
        return data
    }

    // MARK: Files

    /// A file URL from `key`, expanding `~`. The path is not checked for existence here; callers report that.
    func fileURL(_ key: String) throws -> URL {
        let path = try string(key)
        return Self.fileURL(path)
    }

    func optionalFileURL(_ key: String) throws -> URL? {
        guard let path = try optionalString(key) else { return nil }
        return Self.fileURL(path)
    }

    static func fileURL(_ path: String) -> URL {
        if path.hasPrefix("file://"), let url = URL(string: path) { return url }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    // MARK: Formatting

    /// JSON `true`/`false` arrive as `NSNumber` too; this tells them apart from `1` and `0`.
    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

/// An RGBA color in 0–1 components, the exchange form for every color parameter and result.
nonisolated struct AutomationColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init?(any value: Any) {
        if let text = value as? String {
            guard let parsed = AutomationColor(hex: text) else { return nil }
            self = parsed
        } else if let list = value as? [Any] {
            let numbers = list.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == list.count, numbers.count == 3 || numbers.count == 4 else { return nil }
            // Lists above 1 are read as 0–255 bytes, which is how most scripts think about colors.
            let scale: Double = numbers.contains { $0 > 1 } ? 255 : 1
            red = numbers[0] / scale; green = numbers[1] / scale; blue = numbers[2] / scale
            alpha = numbers.count == 4 ? numbers[3] / (numbers[3] > 1 ? 255 : 1) : 1
        } else if let object = value as? [String: Any] {
            func component(_ keys: [String]) -> Double? {
                for key in keys { if let number = object[key] as? NSNumber { return number.doubleValue } }
                return nil
            }
            guard let r = component(["red", "r"]), let g = component(["green", "g"]), let b = component(["blue", "b"]) else { return nil }
            let scale: Double = max(r, g, b) > 1 ? 255 : 1
            red = r / scale; green = g / scale; blue = b / scale
            let a = component(["alpha", "a", "opacity"]) ?? 1
            alpha = a > 1 ? a / 255 : a
        } else {
            return nil
        }
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return nil }
    }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text.removeFirst(2) }
        guard text.count == 6 || text.count == 8 || text.count == 3, let value = UInt64(text, radix: 16) else { return nil }
        switch text.count {
        case 3:
            red = Double((value >> 8) & 0xF) / 15; green = Double((value >> 4) & 0xF) / 15; blue = Double(value & 0xF) / 15; alpha = 1
        case 6:
            red = Double((value >> 16) & 0xFF) / 255; green = Double((value >> 8) & 0xFF) / 255; blue = Double(value & 0xFF) / 255; alpha = 1
        default:
            red = Double((value >> 24) & 0xFF) / 255; green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255; alpha = Double(value & 0xFF) / 255
        }
    }

    var hex: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        if alpha >= 1 { return String(format: "#%02X%02X%02X", r, g, b) }
        return String(format: "#%02X%02X%02X%02X", r, g, b, Int((alpha * 255).rounded()))
    }

    var json: [String: Any] { ["red": red, "green": green, "blue": blue, "alpha": alpha, "hex": hex] }
}

/// Helpers shared by the command implementations for building JSON replies.
nonisolated enum AutomationJSON {
    /// `nil` becomes JSON `null`; anything else is passed through.
    static func nullable(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    static func point(_ point: CGPoint) -> [String: Any] { ["x": Double(point.x), "y": Double(point.y)] }
    static func size(_ size: CGSize) -> [String: Any] { ["width": Double(size.width), "height": Double(size.height)] }
    static func rect(_ rect: CGRect) -> [String: Any] {
        ["x": Double(rect.origin.x), "y": Double(rect.origin.y), "width": Double(rect.width), "height": Double(rect.height)]
    }
}

import Foundation

/// Small helpers for reading loosely typed JSON (`[String: Any]`) the way the printers send it.
enum J {
    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func dict(_ d: [String: Any]?, _ k: String) -> [String: Any]? { d?[k] as? [String: Any] }
    static func array(_ d: [String: Any]?, _ k: String) -> [Any]? { d?[k] as? [Any] }
    static func string(_ d: [String: Any]?, _ k: String) -> String? { d?[k] as? String }

    /// A number, whether it arrived as Int, Double or NSNumber. `nil` for null, missing or non-numeric values.
    static func double(_ d: [String: Any]?, _ k: String) -> Double? { double(d?[k]) }
    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }
    static func int(_ d: [String: Any]?, _ k: String) -> Int? { double(d, k).map { Int($0) } }

    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

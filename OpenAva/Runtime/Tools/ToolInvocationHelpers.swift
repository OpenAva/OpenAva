import Foundation
import OpenClawKit

/// Shared utility methods for tool invocation handlers.
/// These are used by both LocalToolInvokeService and individual Provider extensions.
enum ToolInvocationHelpers {
    // MARK: - Parameter Decoding

    static func decodeParams<T: Decodable>(_ type: T.Type, from json: String?) throws -> T {
        guard let json, let data = json.data(using: .utf8) else {
            throw NSError(domain: "ToolInvocation", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "INVALID_REQUEST: paramsJSON required",
            ])
        }
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Response Helpers

    static func successResponse(id: String, payload: String) -> BridgeInvokeResponse {
        BridgeInvokeResponse(id: id, ok: true, payload: payload)
    }

    static func errorResponse(id: String, code: OpenClawNodeErrorCode, message: String) -> BridgeInvokeResponse {
        BridgeInvokeResponse(id: id, ok: false, error: OpenClawNodeError(code: code, message: message))
    }

    static func invalidRequest(id: String, _ message: String) -> BridgeInvokeResponse {
        errorResponse(id: id, code: .invalidRequest, message: "INVALID_REQUEST: \(message)")
    }

    static func unavailableResponse(id: String, _ message: String) -> BridgeInvokeResponse {
        errorResponse(id: id, code: .unavailable, message: message)
    }

    // MARK: - Payload Encoding

    static func encodePayload(_ obj: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(obj)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw NSError(domain: "ToolInvocation", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode payload as UTF-8",
            ])
        }
        return json
    }

    static func encodePayloadWithMessage(_ payload: some Encodable, message: String) throws -> String {
        let payloadData = try JSONEncoder().encode(payload)
        guard var payloadDict = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw NSError(domain: "ToolInvocation", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Failed to convert payload to dictionary",
            ])
        }
        payloadDict["message"] = message
        let resultData = try JSONSerialization.data(withJSONObject: payloadDict)
        guard let json = String(data: resultData, encoding: .utf8) else {
            throw NSError(domain: "ToolInvocation", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode result as UTF-8",
            ])
        }
        return json
    }

    // MARK: - XML-like Tag Helpers

    static func mimeType(for format: String) -> String {
        switch format.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    static func composeTag(name: String, attributes: [(String, String)]) -> String {
        let attrs = attributes
            .filter { !$0.1.isEmpty }
            .map { key, value in
                "\(key)=\"\(xmlEscaped(value))\""
            }
            .joined(separator: " ")
        return attrs.isEmpty ? "<\(name)/>" : "<\(name) \(attrs)/>"
    }

    static func composeBlock(name: String, attributes: [(String, String)], children: [String]) -> String {
        let start = composeTag(name: name, attributes: attributes)
        guard !children.isEmpty else {
            return start.replacingOccurrences(of: "/>", with: "></\(name)>")
        }
        let open = start.replacingOccurrences(of: "/>", with: ">")
        let body = children.joined(separator: "\n")
        return "\(open)\n\(body)\n</\(name)>"
    }

    static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

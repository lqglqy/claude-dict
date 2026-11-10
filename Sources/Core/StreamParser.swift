import Foundation

struct ResultInfo: Equatable {
    var isError: Bool
    var text: String
    var durationMs: Int?
    var costUSD: Double?
    var apiErrorStatus: Int?
}

/// The parts of `claude -p --output-format stream-json --include-partial-messages` we use.
enum StreamEvent: Equatable {
    case initialized(model: String)
    case textDelta(String)
    case assistantText(String, error: String?)
    case result(ResultInfo)
    case ignored
}

enum StreamParser {
    static func parse(line: String) -> StreamEvent {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return .ignored }
        switch type {
        case "system":
            if object["subtype"] as? String == "init", let model = object["model"] as? String {
                return .initialized(model: model)
            }
            return .ignored
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return .ignored }
            return .textDelta(text)
        case "assistant":
            let message = object["message"] as? [String: Any]
            let content = message?["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            return .assistantText(text, error: object["error"] as? String)
        case "result":
            // Errors such as an unknown model arrive with subtype "success" and is_error true.
            let isError = (object["is_error"] as? Bool) ?? (object["subtype"] as? String != "success")
            return .result(ResultInfo(isError: isError,
                                      text: object["result"] as? String ?? "",
                                      durationMs: (object["duration_ms"] as? NSNumber)?.intValue,
                                      costUSD: (object["total_cost_usd"] as? NSNumber)?.doubleValue,
                                      apiErrorStatus: (object["api_error_status"] as? NSNumber)?.intValue))
        default:
            return .ignored
        }
    }
}

/// Splits a byte stream into lines without breaking multi-byte UTF-8 characters across chunks.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

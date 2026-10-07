// The BashCut plugin protocol for Gipformer Captions (Foundation only). You rarely need to change this file.
//
// BashCut runs the entrypoint as `provider rpc` (one JSON request on stdin, one JSON response on stdout) or, with
// "transport": "session" in plugin.json, as `provider session` (newline-delimited JSON until it says shutdown).
// Handlers.swift gets a `Host` to report progress, stream chat events and call BashCut commands. Diagnostics go to
// stderr: stdout carries only protocol lines.
import Foundation

typealias JSON = [String: Any]

/// A failure with a stable code BashCut can show, such as `PluginError("model_missing", "Install the model")`.
struct PluginError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

struct Cancelled: Error {}

func send(_ message: JSON) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
        FileHandle.standardError.write(Data("could not encode a response\n".utf8))
        return
    }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func readMessage() -> JSON? {
    while let line = readLine(strippingNewline: true) {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON { return object }
        FileHandle.standardError.write(Data("ignored a line that is not a JSON object\n".utf8))
    }
    return nil
}

/// What a handler can do while its request runs.
final class Host {
    let requestId: Any
    let session: Session?
    private var calls = 0

    init(requestId: Any, session: Session?) {
        self.requestId = requestId
        self.session = session
    }

    /// Shows progress on the job (session transport); keeps a long request alive. Send one at least every minute.
    func progress(_ fraction: Double?, _ message: String? = nil) {
        guard session != nil else {
            FileHandle.standardError.write(Data("progress \(fraction.map { "\($0)" } ?? "") \(message ?? "")\n".utf8))
            return
        }
        var line: JSON = ["type": "progress", "id": requestId]
        if let fraction { line["progress"] = min(1, max(0, fraction)) }
        if let message { line["message"] = message }
        send(line)
    }

    /// Hands a UI event to the caller, such as `["kind": "text", "delta": "Hi"]` for a chat agent (API 4).
    func event(_ event: JSON) throws {
        guard session != nil else { throw PluginError("no_host_channel", "Events need the session transport") }
        send(["type": "event", "id": requestId, "event": event])
    }

    /// Runs a BashCut command, such as `try host.call("timeline.get")`, and returns its result (API 4).
    func call(_ method: String, _ params: JSON = [:]) throws -> Any? {
        guard let session else { throw PluginError("no_host_channel", "Calling BashCut needs the session transport") }
        calls += 1
        let callId = "\(requestId)-c\(calls)"
        send(["type": "call", "id": requestId, "callId": callId, "method": method, "params": params])
        let reply = try session.waitForCall(callId, requestId: "\(requestId)")
        if let error = reply["error"] as? JSON {
            throw PluginError("\(error["code"] ?? "call_failed")", error["message"] as? String ?? "BashCut refused the call")
        }
        return reply["result"]
    }
}

func respond(_ request: JSON, session: Session?) -> JSON {
    let id = request["id"] ?? NSNull()
    do {
        let result = try handle(method: request["method"] as? String ?? "", params: request["params"] as? JSON ?? [:],
                                host: Host(requestId: id, session: session))
        return ["id": id, "result": result ?? JSON()]
    } catch let error as PluginError {
        return ["id": id, "error": ["code": error.code, "message": error.message]]
    } catch is Cancelled {
        return ["id": id, "error": ["code": "cancelled", "message": "Cancelled"]]
    } catch {
        return ["id": id, "error": ["code": "failed", "message": "\(error)"]]
    }
}

/// The session transport, one request at a time. Messages that arrive while a handler waits for a call result are
/// kept and handled next, in order.
final class Session {
    private var backlog: [JSON] = []

    func waitForCall(_ callId: String, requestId: String) throws -> JSON {
        while true {
            guard let message = readMessage() else { throw PluginError("host_closed", "BashCut closed the session") }
            let kind = message["type"] as? String
            if kind == "callResult" {
                if message["callId"] as? String == callId { return message }
                continue  // the answer to a call that was given up on
            }
            if kind == "cancel", "\(message["id"] ?? "")" == requestId { throw Cancelled() }
            backlog.append(message)
        }
    }

    func run() {
        while true {
            let next = backlog.isEmpty ? readMessage() : backlog.removeFirst()
            guard let message = next else { return }
            switch message["type"] as? String {
            case "hello": send(["type": "hello", "apiVersion": message["apiVersion"] ?? 2])
            case "shutdown": return
            case "cancel", "callResult": continue
            default: send(respond(message, session: self))
            }
        }
    }
}

if CommandLine.arguments.dropFirst().first == "--version" {
    print(String(cString: SherpaOnnxGetVersionStr()))
} else if CommandLine.arguments.dropFirst().first == "session" {
    Session().run()
} else if let request = readMessage() {
    send(respond(request, session: nil))
} else {
    FileHandle.standardError.write(Data("expected one JSON request on stdin\n".utf8))
    exit(2)
}

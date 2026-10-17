import Foundation

struct ACPAgentCommand: Equatable, Sendable {
    var executable: String
    var arguments: [String]

    init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}

struct DebugACPRequest: Equatable, Sendable {
    var prompt: String
    var agent: ACPAgentCommand
    var cwd: URL
}

struct ACPRunResult: Equatable, Sendable {
    var agentName: String?
    var agentVersion: String?
    var protocolVersion: Int?
    var authMethodCount: Int
    var supportsProviderDiscovery: Bool
    var providers: [ACPProviderSummary]
    var currentModelID: String?
    var availableModels: [ACPModelSummary]
    var responseText: String
}

struct ACPProviderSummary: Equatable, Sendable {
    var id: String
    var isRequired: Bool
    var supportedProtocols: [String]
    var currentProtocol: String?
    var currentBaseURL: String?
}

struct ACPModelSummary: Equatable, Sendable {
    var id: String
    var name: String
    var description: String?
}

protocol ACPClientProtocol {
    func runOneShot(prompt: String) throws -> ACPRunResult
}

struct ACPAgentService {
    var client: ACPClientProtocol
    var log: (String) -> Void

    func runDebugPrompt(_ prompt: String) {
        log("Starting ACP debug session")
        log("You: \(prompt)")

        do {
            let result = try client.runOneShot(prompt: prompt)
            if let agentName = result.agentName {
                if let agentVersion = result.agentVersion {
                    log("Agent: \(agentName) \(agentVersion)")
                } else {
                    log("Agent: \(agentName)")
                }
            }
            if let protocolVersion = result.protocolVersion {
                log("ACP protocol: v\(protocolVersion)")
            }
            log("Auth methods advertised: \(result.authMethodCount)")

            if result.supportsProviderDiscovery {
                if result.providers.isEmpty {
                    log("Providers: discovery supported; no providers returned")
                } else {
                    let providers = result.providers.map { provider in
                        var parts = [provider.id]
                        if let currentProtocol = provider.currentProtocol {
                            parts.append("current=\(currentProtocol)")
                        }
                        if let currentBaseURL = provider.currentBaseURL {
                            parts.append("base=\(currentBaseURL)")
                        }
                        if provider.supportedProtocols.isEmpty == false {
                            parts.append("supported=\(provider.supportedProtocols.joined(separator: ","))")
                        }
                        if provider.isRequired {
                            parts.append("required")
                        }
                        return parts.joined(separator: " ")
                    }
                    log("Providers: \(providers.joined(separator: " | "))")
                }
            } else {
                log("Providers: discovery not advertised by agent")
            }

            if result.availableModels.isEmpty {
                log("Models: no session model state advertised")
            } else {
                let models = result.availableModels.map { model in
                    model.id == result.currentModelID ? "\(model.name) (\(model.id), current)" : "\(model.name) (\(model.id))"
                }
                log("Models: \(models.joined(separator: " | "))")
            }

            log("AI: \(result.responseText)")
            log("Finished ACP debug session")
        } catch {
            log("ACP debug session failed: \(error.localizedDescription)")
        }
    }
}

struct ACPDebugRunner {
    static func run(_ request: DebugACPRequest) {
        let client = ACPStdioClient(command: request.agent, cwd: request.cwd)
        let service = ACPAgentService(client: client, log: log)
        service.runDebugPrompt(request.prompt)
    }

    static func log(_ message: String) {
        let line = "[ACP] \(message)"
        print(line)
        fflush(stdout)
        NSLog("%@", line)
    }
}

final class ACPStdioClient: ACPClientProtocol {
    private let command: ACPAgentCommand
    private let cwd: URL
    private var nextRequestID = 1
    private var readBuffer = Data()
    private let encoder = JSONEncoder()

    init(command: ACPAgentCommand, cwd: URL) {
        self.command = command
        self.cwd = cwd
    }

    func runOneShot(prompt: String) throws -> ACPRunResult {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        configure(process: process, stdin: inputPipe, stdout: outputPipe, stderr: errorPipe)
        try process.run()

        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let writer = inputPipe.fileHandleForWriting
        let reader = outputPipe.fileHandleForReading
        var responseText = ""

        let initializeResult = try sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientInfo": [
                    "name": "InboxZeroMail",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                ],
                "clientCapabilities": [:],
            ],
            writer: writer,
            reader: reader,
            onUpdate: { _ in }
        )

        let supportsProviderDiscovery = initializeResult.dictionaryValue(for: "agentCapabilities")?.keys.contains("providers") == true
        let providers: [ACPProviderSummary]
        if supportsProviderDiscovery {
            providers = (try? sendRequest(
                method: "providers/list",
                params: [:],
                writer: writer,
                reader: reader,
                onUpdate: { _ in }
            ).providersValue()) ?? []
        } else {
            providers = []
        }

        let sessionResult = try sendRequest(
            method: "session/new",
            params: [
                "cwd": cwd.path,
                "mcpServers": [],
            ],
            writer: writer,
            reader: reader,
            onUpdate: { _ in }
        )
        let sessionID = try sessionResult.requiredStringValue(for: "sessionId")
        let modelState = sessionResult.modelStateValue()

        _ = try sendRequest(
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": [
                    [
                        "type": "text",
                        "text": prompt,
                    ],
                ],
            ],
            writer: writer,
            reader: reader,
            onUpdate: { update in
                if let chunk = update.agentMessageTextChunk {
                    responseText.append(chunk)
                }
            }
        )

        try? writer.close()

        return ACPRunResult(
            agentName: initializeResult.dictionaryValue(for: "agentInfo")?.stringValue(for: "name"),
            agentVersion: initializeResult.dictionaryValue(for: "agentInfo")?.stringValue(for: "version"),
            protocolVersion: initializeResult.intValue(for: "protocolVersion"),
            authMethodCount: initializeResult.arrayValue(for: "authMethods")?.count ?? 0,
            supportsProviderDiscovery: supportsProviderDiscovery,
            providers: providers,
            currentModelID: modelState.currentModelID,
            availableModels: modelState.availableModels,
            responseText: responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func configure(process: Process, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
        if command.executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command.executable] + command.arguments
        }
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        writer: FileHandle,
        reader: FileHandle,
        onUpdate: (ACPInboundUpdate) -> Void
    ) throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1

        try writeMessage(
            [
                "jsonrpc": "2.0",
                "id": requestID,
                "method": method,
                "params": params,
            ],
            to: writer
        )

        while true {
            let message = try readMessage(from: reader)
            if message.intValue(for: "id") == requestID {
                if let error = message.dictionaryValue(for: "error") {
                    let message = error.stringValue(for: "message") ?? "ACP request failed."
                    throw ACPError.agentError(message)
                }
                return message.dictionaryValue(for: "result") ?? [:]
            }

            if message.stringValue(for: "method") == "session/update",
               let params = message.dictionaryValue(for: "params") {
                onUpdate(ACPInboundUpdate(params: params))
            } else if let inboundID = message.intValue(for: "id"), message.stringValue(for: "method") != nil {
                try writeMessage(
                    [
                        "jsonrpc": "2.0",
                        "id": inboundID,
                        "error": [
                            "code": -32601,
                            "message": "InboxZeroMail debug ACP client does not implement this client-side method.",
                        ],
                    ],
                    to: writer
                )
            }
        }
    }

    private func writeMessage(_ message: [String: Any], to writer: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        var line = data
        line.append(0x0A)
        try writer.write(contentsOf: line)
    }

    private func readMessage(from reader: FileHandle) throws -> [String: Any] {
        while true {
            if let newlineRange = readBuffer.firstRange(of: Data([0x0A])) {
                let lineData = readBuffer[..<newlineRange.lowerBound]
                readBuffer.removeSubrange(..<newlineRange.upperBound)
                guard lineData.isEmpty == false else { continue }
                let object = try JSONSerialization.jsonObject(with: Data(lineData), options: [])
                guard let message = object as? [String: Any] else {
                    throw ACPError.invalidMessage
                }
                return message
            }

            let data = reader.availableData
            guard data.isEmpty == false else {
                throw ACPError.connectionClosed
            }
            readBuffer.append(data)
        }
    }
}

enum ACPError: LocalizedError {
    case agentError(String)
    case connectionClosed
    case invalidMessage
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .agentError(let message):
            return message
        case .connectionClosed:
            return "The ACP agent closed the connection."
        case .invalidMessage:
            return "The ACP agent returned an invalid JSON-RPC message."
        case .missingField(let field):
            return "The ACP response was missing '\(field)'."
        }
    }
}

private struct ACPInboundUpdate {
    let params: [String: Any]

    var agentMessageTextChunk: String? {
        guard let update = params.dictionaryValue(for: "update"),
              update.stringValue(for: "sessionUpdate") == "agent_message_chunk",
              let content = update.dictionaryValue(for: "content"),
              content.stringValue(for: "type") == "text"
        else {
            return nil
        }
        return content.stringValue(for: "text")
    }
}

private extension Dictionary where Key == String, Value == Any {
    func requiredStringValue(for key: String) throws -> String {
        guard let value = stringValue(for: key), value.isEmpty == false else {
            throw ACPError.missingField(key)
        }
        return value
    }

    func stringValue(for key: String) -> String? {
        self[key] as? String
    }

    func intValue(for key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? NSNumber { return value.intValue }
        return nil
    }

    func arrayValue(for key: String) -> [Any]? {
        self[key] as? [Any]
    }

    func dictionaryValue(for key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func providersValue() -> [ACPProviderSummary] {
        guard let rawProviders = self["providers"] as? [[String: Any]] else { return [] }
        return rawProviders.compactMap { provider in
            guard let id = provider.stringValue(for: "id") else { return nil }
            let current = provider.dictionaryValue(for: "current")
            return ACPProviderSummary(
                id: id,
                isRequired: (provider["required"] as? Bool) ?? false,
                supportedProtocols: provider["supported"] as? [String] ?? [],
                currentProtocol: current?.stringValue(for: "apiType"),
                currentBaseURL: current?.stringValue(for: "baseUrl")
            )
        }
    }

    func modelStateValue() -> (currentModelID: String?, availableModels: [ACPModelSummary]) {
        guard let models = dictionaryValue(for: "models") else { return (nil, []) }
        let available = (models["availableModels"] as? [[String: Any]])?.compactMap { model -> ACPModelSummary? in
            guard let id = model.stringValue(for: "modelId"),
                  let name = model.stringValue(for: "name")
            else {
                return nil
            }
            return ACPModelSummary(
                id: id,
                name: name,
                description: model.stringValue(for: "description")
            )
        } ?? []
        return (models.stringValue(for: "currentModelId"), available)
    }
}

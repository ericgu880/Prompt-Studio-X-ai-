import Foundation
import PromptStudioCore

private let protocolVersion = "2024-11-05"

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private enum MCPError: Error, LocalizedError {
    case invalidRequest(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .unknownTool(let message):
            message
        }
    }
}

private struct StdioTransport {
    func readMessage() -> [String: Any]? {
        guard let header = readHeader(), let contentLength = parseContentLength(header) else {
            return nil
        }
        let body = FileHandle.standardInput.readData(ofLength: contentLength)
        guard body.count == contentLength,
              let object = try? JSONSerialization.jsonObject(with: body),
              let message = object as? [String: Any] else {
            return nil
        }
        return message
    }

    func writeMessage(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message, options: []) else {
            return
        }
        let header = "Content-Length: \(body.count)\r\n\r\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        FileHandle.standardOutput.write(body)
        fflush(stdout)
    }

    private func readHeader() -> String? {
        var bytes: [UInt8] = []
        while true {
            let data = FileHandle.standardInput.readData(ofLength: 1)
            guard let byte = data.first else {
                return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
            }
            bytes.append(byte)
            if bytes.suffix(4) == [13, 10, 13, 10] {
                return String(bytes: bytes, encoding: .utf8)
            }
        }
    }

    private func parseContentLength(_ header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame else {
                continue
            }
            return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

private final class PromptStudioMCPServer {
    private let transport = StdioTransport()
    private let service: PromptStudioAutomationService

    init(arguments: [String]) throws {
        self.service = try PromptStudioAutomationService(libraryURL: Self.libraryURL(from: arguments))
    }

    func run() {
        while let message = transport.readMessage() {
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let method = message["method"] as? String else {
            if message["id"] != nil {
                writeError(id: message["id"], code: -32600, message: "Missing method")
            }
            return
        }

        if method.hasPrefix("notifications/") {
            return
        }

        guard let id = message["id"] else {
            return
        }

        do {
            switch method {
            case "initialize":
                writeResult(id: id, result: initializeResult)
            case "ping":
                writeResult(id: id, result: [:])
            case "tools/list":
                writeResult(id: id, result: ["tools": toolDefinitions])
            case "tools/call":
                let result = try callTool(params: message["params"] as? [String: Any] ?? [:])
                writeResult(id: id, result: result)
            default:
                writeError(id: id, code: -32601, message: "Unknown method: \(method)")
            }
        } catch {
            writeError(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private var initializeResult: [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "capabilities": [
                "tools": ["listChanged": false]
            ],
            "serverInfo": [
                "name": "PromptStudioMCP",
                "version": "0.1.0"
            ]
        ]
    }

    private var toolDefinitions: [[String: Any]] {
        [
            tool("list_items", "List PromptStudio items.", [
                "query": stringSchema("Search query"),
                "model": stringSchema("Model id or name"),
                "folder_id": stringSchema("Folder id"),
                "include_trash": boolSchema("List trash instead of active library")
            ]),
            tool("get_item", "Get one item by id.", [
                "id": stringSchema("Item id")
            ], required: ["id"]),
            tool("list_folders", "List folders.", [:]),
            tool("create_prompt", "Create a text prompt item.", [
                "title": stringSchema("Prompt title"),
                "prompt": stringSchema("Prompt text"),
                "negative": stringSchema("Negative prompt"),
                "tags": stringArraySchema("Tags"),
                "model": stringSchema("Model id or name"),
                "folder_id": stringSchema("Folder id")
            ], required: ["title", "prompt"]),
            tool("update_prompt", "Update prompt metadata and append a new version when prompt text changes.", [
                "id": stringSchema("Item id"),
                "title": stringSchema("Prompt title"),
                "prompt": stringSchema("Prompt text"),
                "negative": stringSchema("Negative prompt"),
                "tags": stringArraySchema("Replacement tags"),
                "folder_id": stringSchema("Folder id")
            ], required: ["id"]),
            tool("import_files", "Import files into the local library.", [
                "paths": stringArraySchema("Absolute file paths"),
                "folder_id": stringSchema("Folder id")
            ], required: ["paths"]),
            tool("move_item", "Move an item to a folder.", [
                "id": stringSchema("Item id"),
                "folder_id": stringSchema("Folder id")
            ], required: ["id", "folder_id"]),
            tool("add_tags", "Add tags to an item.", [
                "id": stringSchema("Item id"),
                "tags": stringArraySchema("Tags to add")
            ], required: ["id", "tags"]),
            tool("favorite_item", "Set favorite state.", [
                "id": stringSchema("Item id"),
                "favorite": boolSchema("Favorite state")
            ], required: ["id", "favorite"]),
            tool("trash_item", "Move an item to trash.", [
                "id": stringSchema("Item id")
            ], required: ["id"]),
            tool("restore_item", "Restore an item from trash.", [
                "id": stringSchema("Item id")
            ], required: ["id"])
        ]
    }

    private func callTool(params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else {
            throw MCPError.invalidRequest("tools/call requires name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let value: Any
        switch name {
        case "list_items":
            value = try service.listItems(
                options: AutomationListOptions(
                    query: string(arguments, "query") ?? "",
                    model: string(arguments, "model"),
                    folderID: string(arguments, "folder_id"),
                    includeTrash: bool(arguments, "include_trash") ?? false
                )
            )
        case "get_item":
            value = try service.item(id: requiredString(arguments, "id"))
        case "list_folders":
            value = try service.folders()
        case "create_prompt":
            value = try service.createPrompt(
                AutomationCreatePromptInput(
                    title: requiredString(arguments, "title"),
                    prompt: requiredString(arguments, "prompt"),
                    negativePrompt: string(arguments, "negative") ?? "",
                    tags: stringArray(arguments, "tags"),
                    model: string(arguments, "model"),
                    folderID: string(arguments, "folder_id")
                )
            )
        case "update_prompt":
            value = try service.updatePrompt(
                id: requiredString(arguments, "id"),
                input: AutomationUpdatePromptInput(
                    title: string(arguments, "title"),
                    prompt: string(arguments, "prompt"),
                    negativePrompt: string(arguments, "negative"),
                    tags: arguments["tags"] == nil ? nil : stringArray(arguments, "tags"),
                    folderID: string(arguments, "folder_id")
                )
            )
        case "import_files":
            value = try service.importFiles(paths: requiredStringArray(arguments, "paths"), folderID: string(arguments, "folder_id"))
        case "move_item":
            value = try service.moveItem(itemID: requiredString(arguments, "id"), folderID: requiredString(arguments, "folder_id"))
        case "add_tags":
            value = try service.addTags(itemID: requiredString(arguments, "id"), tags: requiredStringArray(arguments, "tags"))
        case "favorite_item":
            value = try service.setFavorite(itemID: requiredString(arguments, "id"), favorite: bool(arguments, "favorite") ?? false)
        case "trash_item":
            try service.markDeleted(itemID: requiredString(arguments, "id"))
            value = ["ok": true]
        case "restore_item":
            try service.restore(itemID: requiredString(arguments, "id"))
            value = ["ok": true]
        default:
            throw MCPError.unknownTool("Unknown tool: \(name)")
        }
        return textResult(value)
    }

    private func textResult(_ value: Any) -> [String: Any] {
        let text: String
        if let encodable = value as? any Encodable,
           let data = try? encoder.encode(AnyEncodable(encodable)),
           let encodedText = String(data: data, encoding: .utf8) {
            text = encodedText
        } else if JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let encodedText = String(data: data, encoding: .utf8) {
            text = encodedText
        } else {
            text = "\(value)"
        }
        return [
            "content": [
                ["type": "text", "text": text]
            ],
            "isError": false
        ]
    }

    private func writeResult(id: Any, result: [String: Any]) {
        transport.writeMessage([
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ])
    }

    private func writeError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        response["id"] = id ?? NSNull()
        transport.writeMessage(response)
    }

    private static func libraryURL(from arguments: [String]) -> URL {
        PromptRepository.resolvedLibraryURL(arguments: arguments)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
    [
        "name": name,
        "description": description,
        "inputSchema": [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    ]
}

private func stringSchema(_ description: String) -> [String: Any] {
    ["type": "string", "description": description]
}

private func boolSchema(_ description: String) -> [String: Any] {
    ["type": "boolean", "description": description]
}

private func stringArraySchema(_ description: String) -> [String: Any] {
    [
        "type": "array",
        "description": description,
        "items": ["type": "string"]
    ]
}

private func string(_ arguments: [String: Any], _ key: String) -> String? {
    arguments[key] as? String
}

private func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
    guard let value = string(arguments, key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw MCPError.invalidRequest("Missing required argument: \(key)")
    }
    return value
}

private func bool(_ arguments: [String: Any], _ key: String) -> Bool? {
    arguments[key] as? Bool
}

private func stringArray(_ arguments: [String: Any], _ key: String) -> [String] {
    arguments[key] as? [String] ?? []
}

private func requiredStringArray(_ arguments: [String: Any], _ key: String) throws -> [String] {
    let values = stringArray(arguments, key).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard !values.isEmpty else {
        throw MCPError.invalidRequest("Missing required argument: \(key)")
    }
    return values
}

do {
    try PromptStudioMCPServer(arguments: Array(CommandLine.arguments.dropFirst())).run()
} catch {
    fputs("PromptStudioMCP: \(error.localizedDescription)\n", stderr)
    exit(1)
}

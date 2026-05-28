import Foundation
import PromptStudioCore

private struct CommandOptions {
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var positionals: [String] = []

    func value(_ name: String) -> String? {
        values[name]
    }

    func has(_ name: String) -> Bool {
        flags.contains(name) || values[name] != nil
    }
}

private enum CLIError: Error, LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        }
    }
}

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private func parseGlobalArguments(_ arguments: [String]) throws -> (libraryURL: URL, command: String, options: CommandOptions) {
    var tokens = arguments
    var libraryURL = PromptRepository.defaultLibraryURL()
    while let first = tokens.first {
        if first == "--library" {
            guard tokens.count >= 2 else { throw CLIError.usage("--library 需要路径") }
            libraryURL = URL(fileURLWithPath: tokens[1])
            tokens.removeFirst(2)
        } else if first.hasPrefix("--library=") {
            libraryURL = URL(fileURLWithPath: String(first.dropFirst("--library=".count)))
            tokens.removeFirst()
        } else {
            break
        }
    }
    guard let command = tokens.first else {
        throw CLIError.usage(helpText)
    }
    tokens.removeFirst()
    return (libraryURL, command, parseCommandOptions(tokens))
}

private func parseCommandOptions(_ tokens: [String]) -> CommandOptions {
    var options = CommandOptions()
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        if token.hasPrefix("--") {
            let nameAndValue = token.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
            let name = nameAndValue[0]
            if nameAndValue.count == 2 {
                options.values[name] = nameAndValue[1]
            } else if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                options.values[name] = tokens[index + 1]
                index += 1
            } else {
                options.flags.insert(name)
            }
        } else {
            options.positionals.append(token)
        }
        index += 1
    }
    return options
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func tags(from raw: String?) -> [String] {
    guard let raw else { return [] }
    return raw.split(separator: ",").map(String.init)
}

private func require(_ options: CommandOptions, _ name: String) throws -> String {
    guard let value = options.value(name), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError.usage("缺少参数 --\(name)")
    }
    return value
}

private let helpText = """
PromptStudio agent CLI

Usage:
  promptstudioctl [--library PATH] list [--query TEXT] [--model ID_OR_NAME] [--folder-id ID] [--trash]
  promptstudioctl [--library PATH] get ITEM_ID
  promptstudioctl [--library PATH] folders
  promptstudioctl [--library PATH] create-folder --name NAME [--parent-id ID]
  promptstudioctl [--library PATH] create-prompt --title TITLE --prompt TEXT [--negative TEXT] [--tags a,b] [--model NAME] [--folder-id ID]
  promptstudioctl [--library PATH] update-prompt ITEM_ID [--title TITLE] [--prompt TEXT] [--negative TEXT] [--tags a,b] [--folder-id ID]
  promptstudioctl [--library PATH] add-tags ITEM_ID --tags a,b
  promptstudioctl [--library PATH] favorite ITEM_ID --on|--off
  promptstudioctl [--library PATH] move ITEM_ID --folder-id ID
  promptstudioctl [--library PATH] delete ITEM_ID
  promptstudioctl [--library PATH] restore ITEM_ID
  promptstudioctl [--library PATH] import PATH... [--folder-id ID]

All data commands print JSON for agent consumption.
"""

do {
    let parsed = try parseGlobalArguments(Array(CommandLine.arguments.dropFirst()))
    let service = try PromptStudioAutomationService(libraryURL: parsed.libraryURL)
    let options = parsed.options

    switch parsed.command {
    case "help", "--help", "-h":
        print(helpText)
    case "list":
        let items = try service.listItems(
            options: AutomationListOptions(
                query: options.value("query") ?? "",
                model: options.value("model"),
                folderID: options.value("folder-id"),
                includeTrash: options.has("trash")
            )
        )
        try writeJSON(items)
    case "get":
        guard let id = options.positionals.first else { throw CLIError.usage("get 需要 ITEM_ID") }
        try writeJSON(try service.item(id: id))
    case "folders":
        try writeJSON(try service.folders())
    case "create-folder":
        let folder = try service.createFolder(name: require(options, "name"), parentID: options.value("parent-id"))
        try writeJSON(folder)
    case "create-prompt":
        let item = try service.createPrompt(
            AutomationCreatePromptInput(
                title: require(options, "title"),
                prompt: require(options, "prompt"),
                negativePrompt: options.value("negative") ?? "",
                tags: tags(from: options.value("tags")),
                model: options.value("model"),
                folderID: options.value("folder-id")
            )
        )
        try writeJSON(item)
    case "update-prompt":
        guard let id = options.positionals.first else { throw CLIError.usage("update-prompt 需要 ITEM_ID") }
        let item = try service.updatePrompt(
            id: id,
            input: AutomationUpdatePromptInput(
                title: options.value("title"),
                prompt: options.value("prompt"),
                negativePrompt: options.value("negative"),
                tags: options.value("tags").map { tags(from: $0) },
                folderID: options.value("folder-id")
            )
        )
        try writeJSON(item)
    case "add-tags":
        guard let id = options.positionals.first else { throw CLIError.usage("add-tags 需要 ITEM_ID") }
        try writeJSON(try service.addTags(itemID: id, tags: tags(from: require(options, "tags"))))
    case "favorite":
        guard let id = options.positionals.first else { throw CLIError.usage("favorite 需要 ITEM_ID") }
        guard options.has("on") != options.has("off") else { throw CLIError.usage("favorite 需要 --on 或 --off") }
        try writeJSON(try service.setFavorite(itemID: id, favorite: options.has("on")))
    case "move":
        guard let id = options.positionals.first else { throw CLIError.usage("move 需要 ITEM_ID") }
        try writeJSON(try service.moveItem(itemID: id, folderID: require(options, "folder-id")))
    case "delete":
        guard let id = options.positionals.first else { throw CLIError.usage("delete 需要 ITEM_ID") }
        try service.markDeleted(itemID: id)
        try writeJSON(["ok": true])
    case "restore":
        guard let id = options.positionals.first else { throw CLIError.usage("restore 需要 ITEM_ID") }
        try service.restore(itemID: id)
        try writeJSON(["ok": true])
    case "import":
        guard !options.positionals.isEmpty else { throw CLIError.usage("import 需要至少一个文件路径") }
        try writeJSON(try service.importFiles(paths: options.positionals, folderID: options.value("folder-id")))
    default:
        throw CLIError.usage("未知命令：\(parsed.command)\n\n\(helpText)")
    }
} catch {
    fputs("promptstudioctl: \(error.localizedDescription)\n", stderr)
    exit(1)
}

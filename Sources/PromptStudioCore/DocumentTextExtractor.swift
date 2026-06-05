import Foundation

#if canImport(AppKit)
import AppKit
#endif

public enum DocumentTextExtractor {
    public static func readText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if isRichDocumentExtension(ext) {
            return richDocumentText(from: url) ?? plainText(from: url)
        }
        return plainText(from: url)
    }

    private static func plainText(from url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .utf16),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }

    private static func richDocumentText(from url: URL) -> String? {
        attributedDocumentText(from: url) ?? textutilText(from: url)
    }

    private static func isRichDocumentExtension(_ ext: String) -> Bool {
        ["doc", "docx", "rtf"].contains(ext)
    }

    #if canImport(AppKit)
    private static func attributedDocumentText(from url: URL) -> String? {
        guard let documentType = attributedDocumentType(for: url.pathExtension.lowercased()),
              let attributed = try? NSAttributedString(
                url: url,
                options: [.documentType: documentType],
                documentAttributes: nil
              ) else {
            return nil
        }
        let text = attributed.string
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func attributedDocumentType(for ext: String) -> NSAttributedString.DocumentType? {
        switch ext {
        case "docx":
            return .officeOpenXML
        case "doc":
            return .docFormat
        case "rtf":
            return .rtf
        default:
            return nil
        }
    }
    #else
    private static func attributedDocumentText(from url: URL) -> String? {
        nil
    }
    #endif

    private static func textutilText(from url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : text
    }
}

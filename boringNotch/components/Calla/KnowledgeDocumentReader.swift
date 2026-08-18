import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Turns a dropped file into text the copilot can search.
///
/// Extraction happens here, in the app, rather than in the engine — even though
/// the engine is unsandboxed and could read the file itself. Two reasons, and the
/// first is the one that matters: a drag-and-drop grants *this* process read
/// access to that file and nothing else, so doing the read here keeps the
/// permission exactly as wide as the user's gesture. Handing the engine a path
/// would have an unsandboxed process opening an arbitrary location on the say-so
/// of a message. The second is that PDFKit and Vision live on this side anyway.
///
/// Only text crosses the boundary. The original file is never copied, moved, or
/// stored — the store holds what was read out of it, and the filename.
enum KnowledgeDocumentReader {
    struct Document {
        var name: String
        /// `pdf`, `rich`, `text`, `image`.
        var kind: String
        var text: String
        var byteSize: Int
        var pageCount: Int
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        case empty(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(name): "\(name) is not a kind of file this can read."
            case let .empty(name): "\(name) has no text in it to read."
            case let .tooLarge(name): "\(name) is too large to attach."
            }
        }
    }

    /// Ceiling on extracted text, not on the file.
    ///
    /// A 2 MB novel of extracted text is perfectly usable — it is chunked and
    /// searched, never sent whole — but it is also a hundred thousand chunks to
    /// embed, and somebody dropping a 900-page PDF should be told rather than left
    /// watching a spinner. Generous enough that ordinary contracts, decks and
    /// reports never hit it.
    static let maxCharacters = 2_000_000

    /// What a drop can carry.
    static let readableTypes: [UTType] = [
        .pdf, .rtf, .rtfd, .plainText, .utf8PlainText, .text, .html, .xml,
        .commaSeparatedText, .tabSeparatedText, .json, .yaml, .sourceCode,
        .image, .png, .jpeg, .heic,
        // Word and OpenDocument have no system UTType constant; both are read
        // through `NSAttributedString`, which handles them.
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
    ].compactMap { $0 }

    static func canRead(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            // No extension is not a refusal: a plain text file often has none, and
            // the reader below finds out for certain by trying.
            return true
        }
        return readableTypes.contains { type.conforms(to: $0) }
    }

    /// Reads one file. Blocking — callers run it off the main actor.
    ///
    /// Security-scoped access is requested and released around the read. A
    /// dropped file usually does not need it, but one arriving from a bookmark or
    /// another app's container does, and asking when it is unnecessary costs
    /// nothing.
    static func read(_ url: URL) throws -> Document {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let byteSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let type = UTType(filenameExtension: url.pathExtension)

        var text = ""
        var kind = "text"
        var pages = 0

        if type?.conforms(to: .pdf) == true {
            let extracted = try readPDF(url, name: name)
            text = extracted.text
            pages = extracted.pages
            kind = extracted.usedOCR ? "image" : "pdf"
        } else if type?.conforms(to: .image) == true {
            text = try recogniseText(in: url, name: name)
            kind = "image"
        } else if let rich = try? NSAttributedString(
            url: url, options: [:], documentAttributes: nil), !rich.string.isEmpty {
            // Covers RTF, RTFD, DOC, DOCX, ODT and HTML in one call.
            text = rich.string
            kind = "rich"
        } else if let plain = try? String(contentsOf: url, encoding: .utf8) {
            text = plain
        } else if let data = try? Data(contentsOf: url),
                  let guessed = String(data: data, encoding: .isoLatin1) {
            // Last resort for a text file in an encoding UTF-8 refused. Latin-1
            // never fails, which is exactly why it is last: it will happily turn
            // binary into mojibake, so the emptiness check below is what stops a
            // dropped executable becoming a "document".
            text = guessed
        } else {
            throw Failure.unreadable(name)
        }

        text = tidy(text)
        guard text.count <= maxCharacters else { throw Failure.tooLarge(name) }
        guard looksLikeProse(text) else { throw Failure.empty(name) }

        return Document(name: name, kind: kind, text: text, byteSize: byteSize, pageCount: pages)
    }

    // MARK: - PDF

    private static func readPDF(_ url: URL, name: String) throws -> (text: String, pages: Int, usedOCR: Bool) {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable(name) }
        let pages = document.pageCount

        var parts: [String] = []
        for index in 0 ..< pages {
            guard let page = document.page(at: index), let text = page.string else { continue }
            parts.append(text)
        }
        let text = tidy(parts.joined(separator: "\n\n"))

        // A scanned contract is a PDF whose pages are images: PDFKit returns
        // almost nothing and the file looks empty. That is the single most likely
        // thing somebody drags in, so it falls through to OCR rather than being
        // refused.
        if looksLikeProse(text) { return (text, pages, false) }
        return (try recogniseText(inPDF: document, name: name), pages, true)
    }

    // MARK: - OCR

    private static func recogniseText(in url: URL, name: String) throws -> String {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw Failure.unreadable(name) }
        return recognise(cgImage)
    }

    /// OCR over a scanned PDF, page by page.
    ///
    /// Bounded at forty pages. Vision is roughly a third of a second per page on
    /// Apple silicon, so a whole scanned book would be minutes of work started by
    /// a drag — and the first forty pages of a scanned document are nearly always
    /// the part someone wants to ask about.
    private static func recogniseText(inPDF document: PDFDocument, name: String) throws -> String {
        let limit = min(document.pageCount, 40)
        guard limit > 0 else { throw Failure.empty(name) }

        var parts: [String] = []
        for index in 0 ..< limit {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // 2× for legibility: Vision reads 150dpi far better than 72.
            let scale: CGFloat = 2
            let width = Int(bounds.width * scale)
            let height = Int(bounds.height * scale)
            guard width > 0, height > 0,
                  let context = CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { continue }

            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: context)

            if let cgImage = context.makeImage() {
                let text = recognise(cgImage)
                if !text.isEmpty { parts.append(text) }
            }
        }
        let text = tidy(parts.joined(separator: "\n\n"))
        guard looksLikeProse(text) else { throw Failure.empty(name) }
        return text
    }

    private static func recognise(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    // MARK: - Cleanup

    /// Collapses the whitespace a PDF extraction leaves behind.
    ///
    /// Worth doing before chunking rather than after: paragraph boundaries are what
    /// the chunker splits on, and a page break rendered as six blank lines makes
    /// every paragraph its own chunk.
    private static func tidy(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\u{00AD}", with: "")     // soft hyphen
        value = value.replacingOccurrences(of: "\u{FEFF}", with: "")     // BOM
        value = value.replacingOccurrences(
            of: "[ \\t]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this is text worth indexing rather than the residue of a binary
    /// file read as if it were text.
    ///
    /// The Latin-1 fallback above cannot fail, so something has to decide that a
    /// dropped `.dylib` is not a document. Letters-to-length is a cruder test than
    /// sniffing the format and a much more reliable one.
    private static func looksLikeProse(_ text: String) -> Bool {
        guard text.count >= 24 else { return false }
        let sample = text.prefix(4000)
        let letters = sample.reduce(into: 0) { count, character in
            if character.isLetter || character.isWhitespace { count += 1 }
        }
        return Double(letters) / Double(sample.count) > 0.7
    }
}

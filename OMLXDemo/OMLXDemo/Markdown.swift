import SwiftUI

extension AttributedString {
    /// Markdown laid out for `Text`, which shows inline styles but not block
    /// structure. Single line breaks become spaces, as Markdown intends; blocks
    /// are separated by blank lines; list items get their markers.
    init(blockMarkdown markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            self.init(markdown)
            return
        }

        self.init()
        var previous: PresentationIntent?
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var block = AttributedString(parsed[range])
            if let previous {
                let isListContinuation = previous.listMarker != nil && intent?.listMarker != nil
                append(AttributedString(isListContinuation ? "\n" : "\n\n"))
            }
            if let marker = intent?.listMarker {
                block = AttributedString(marker) + block
            }
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header:
                    block.swiftUI.font = .headline
                case .codeBlock:
                    block.swiftUI.font = .body.monospaced()
                    if block.characters.last == "\n" {
                        block.characters.removeLast()
                    }
                default:
                    break
                }
            }
            append(block)
            previous = intent
        }
    }
}

private extension PresentationIntent {
    /// "• " or "1. ", indented for nested lists; `nil` outside a list.
    var listMarker: String? {
        let kinds = components.map(\.kind)
        guard let itemIndex = kinds.firstIndex(where: { if case .listItem = $0 { true } else { false } }),
              case .listItem(let ordinal) = kinds[itemIndex]
        else { return nil }
        let depth = kinds.count { $0 == .orderedList || $0 == .unorderedList }
        let indent = String(repeating: "    ", count: max(depth - 1, 0))
        let isOrdered = kinds.dropFirst(itemIndex + 1).first == .orderedList
        return indent + (isOrdered ? "\(ordinal). " : "• ")
    }
}

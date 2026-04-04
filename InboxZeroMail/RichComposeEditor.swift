import AppKit
import DesignSystem
import SwiftUI

struct RichComposeEditor: NSViewRepresentable {
    let plainText: String
    let htmlText: String?
    let autoFocus: Bool
    let onChange: (String, String?) -> Void

    func makeNSView(context: Context) -> RichComposeEditorContainer {
        let view = RichComposeEditorContainer()
        view.onChange = onChange
        view.applyExternalContent(plainText: plainText, htmlText: htmlText)
        if autoFocus {
            DispatchQueue.main.async {
                view.focusEditor()
            }
        }
        return view
    }

    func updateNSView(_ nsView: RichComposeEditorContainer, context: Context) {
        nsView.onChange = onChange
        nsView.applyExternalContent(plainText: plainText, htmlText: htmlText)
        if autoFocus, nsView.window?.firstResponder !== nsView.textView {
            DispatchQueue.main.async {
                nsView.focusEditor()
            }
        }
    }
}

final class RichComposeEditorContainer: NSView, NSTextViewDelegate {
    let textView = ComposeRichTextView()

    var onChange: ((String, String?) -> Void)?

    private let scrollView = NSScrollView()
    private let selectionToolbar: ComposeSelectionToolbarView
    private var isApplyingExternalContent = false
    private var lastPlainText = ""
    private var lastHTMLText: String?

    override init(frame frameRect: NSRect) {
        selectionToolbar = ComposeSelectionToolbarView()
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyExternalContent(plainText: String, htmlText: String?) {
        let normalizedHTML = htmlText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plainText != lastPlainText || normalizedHTML != lastHTMLText else { return }

        isApplyingExternalContent = true
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(Self.makeAttributedString(plainText: plainText, htmlText: normalizedHTML))
        textView.typingAttributes = Self.defaultTypingAttributes()
        textView.setSelectedRange(NSRange(location: min(selection.location, (textView.string as NSString).length), length: 0))
        lastPlainText = plainText
        lastHTMLText = normalizedHTML
        isApplyingExternalContent = false
        refreshSelectionToolbar()
    }

    func focusEditor() {
        guard let window else { return }
        window.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        guard isApplyingExternalContent == false else { return }
        syncDraftContent()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        normalizeTypingAttributes()
        refreshSelectionToolbar()
    }

    func refreshSelectionToolbar() {
        guard window?.firstResponder === textView else {
            selectionToolbar.isHidden = true
            return
        }

        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            selectionToolbar.isHidden = true
            return
        }

        let screenRect = textView.firstRect(forCharacterRange: selection, actualRange: nil)
        guard screenRect.isEmpty == false, let window else {
            selectionToolbar.isHidden = true
            return
        }

        let windowRect = window.convertFromScreen(screenRect)
        let localRect = convert(windowRect, from: nil)
        let size = selectionToolbar.fittingSize
        let maxX = max(12, bounds.width - size.width - 12)
        let maxY = max(12, bounds.height - size.height - 12)
        let origin = NSPoint(
            x: min(max(12, localRect.midX - (size.width / 2)), maxX),
            y: min(max(12, localRect.maxY + 8), maxY)
        )

        selectionToolbar.frame = NSRect(origin: origin, size: size)
        selectionToolbar.updateState(from: textView)
        selectionToolbar.isHidden = false
    }

    func handleCommandShortcut(_ key: String) -> Bool {
        switch key {
        case "b":
            toggleBold()
        case "i":
            toggleItalic()
        case "u":
            toggleUnderline()
        default:
            return false
        }
        return true
    }

    func handleInsertedText(_ insertedText: String) {
        guard insertedText == " " else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }

        let nsString = textView.string as NSString
        let location = max(selection.location - 1, 0)
        let paragraphRange = nsString.paragraphRange(for: NSRange(location: location, length: 0))
        let paragraph = nsString.substring(with: paragraphRange).replacingOccurrences(of: "\n", with: "")

        if ["- ", "* ", "+ "].contains(paragraph) {
            convertMarkdownListTrigger(in: paragraphRange, ordered: false)
        } else if paragraph.range(of: #"^\d+[.)]\s$"#, options: .regularExpression) != nil {
            convertMarkdownListTrigger(in: paragraphRange, ordered: true)
        }
    }

    func toggleBold() {
        toggleFontTrait(.boldFontMask)
    }

    func toggleItalic() {
        toggleFontTrait(.italicFontMask)
    }

    func toggleUnderline() {
        let selection = textView.selectedRange()
        if selection.length == 0 {
            let currentValue = (textView.typingAttributes[.underlineStyle] as? Int) ?? 0
            var updated = textView.typingAttributes
            updated[.underlineStyle] = currentValue == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = updated
            selectionToolbar.updateState(from: textView)
            return
        }

        guard let storage = textView.textStorage else { return }
        let shouldUnderline = allRunsMatch(in: selection, attribute: .underlineStyle) { value in
            ((value as? Int) ?? 0) != 0
        } == false

        storage.beginEditing()
        storage.enumerateAttribute(.underlineStyle, in: selection) { _, range, _ in
            storage.addAttribute(
                .underlineStyle,
                value: shouldUnderline ? NSUnderlineStyle.single.rawValue : 0,
                range: range
            )
        }
        storage.endEditing()
        syncDraftContent()
    }

    func toggleUnorderedList() {
        toggleList(ordered: false)
    }

    func toggleOrderedList() {
        toggleList(ordered: true)
    }

    private func setup() {
        wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        textView.owner = self
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor(MailDesignTokens.textPrimary)
        textView.insertionPointColor = NSColor(MailDesignTokens.textPrimary)
        textView.selectedTextAttributes = Self.selectedTextAttributes()
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 10)
        textView.font = Self.defaultFont
        textView.typingAttributes = Self.defaultTypingAttributes()

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        addSubview(scrollView)

        selectionToolbar.translatesAutoresizingMaskIntoConstraints = true
        selectionToolbar.editor = self
        selectionToolbar.isHidden = true
        addSubview(selectionToolbar)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        normalizeTypingAttributes()
    }

    private func syncDraftContent() {
        let plainText = textView.string
        let htmlText = Self.serializedHTML(from: textView.attributedString())
        lastPlainText = plainText
        lastHTMLText = htmlText?.trimmingCharacters(in: .whitespacesAndNewlines)
        onChange?(plainText, htmlText)
        refreshSelectionToolbar()
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        let selection = textView.selectedRange()
        if selection.length == 0 {
            let currentFont = (textView.typingAttributes[.font] as? NSFont) ?? Self.defaultFont
            let updated = toggledFont(from: currentFont, trait: trait)
            var typingAttributes = textView.typingAttributes
            typingAttributes[.font] = updated
            textView.typingAttributes = typingAttributes
            selectionToolbar.updateState(from: textView)
            return
        }

        guard let storage = textView.textStorage else { return }
        let shouldApplyTrait = allRunsMatch(in: selection, attribute: .font) { value in
            guard let font = value as? NSFont else { return false }
            return NSFontManager.shared.traits(of: font).contains(trait)
        } == false

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: selection) { value, range, _ in
            let currentFont = (value as? NSFont) ?? Self.defaultFont
            let updated = updatedFont(from: currentFont, trait: trait, shouldApply: shouldApplyTrait)
            storage.addAttribute(.font, value: updated, range: range)
        }
        storage.endEditing()
        syncDraftContent()
    }

    private func toggleList(ordered: Bool) {
        let nsString = textView.string as NSString
        let paragraphRanges = paragraphRanges(for: textView.selectedRange(), in: nsString)
        let shouldApplyList = paragraphRanges.allSatisfy { range in
            paragraphStyle(at: range.location).textLists.contains(where: { list in
                list.markerFormat == (ordered ? .decimal : .disc)
            })
        } == false

        let updatedStyle: (NSParagraphStyle) -> NSMutableParagraphStyle = { current in
            let style = current.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            if shouldApplyList {
                style.textLists = [NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)]
                style.firstLineHeadIndent = 26
                style.headIndent = 26
                style.tabStops = [NSTextTab(textAlignment: .left, location: 26, options: [:])]
            } else {
                style.textLists = []
                style.firstLineHeadIndent = 0
                style.headIndent = 0
                style.tabStops = []
            }
            return style
        }

        if paragraphRanges.allSatisfy({ $0.length == 0 }) {
            var typingAttributes = textView.typingAttributes
            typingAttributes[.paragraphStyle] = updatedStyle(paragraphStyle(at: max(textView.selectedRange().location - 1, 0)))
            textView.typingAttributes = typingAttributes
            selectionToolbar.updateState(from: textView)
            return
        }

        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        for range in paragraphRanges where range.length > 0 {
            storage.addAttribute(.paragraphStyle, value: updatedStyle(paragraphStyle(at: range.location)), range: range)
        }
        storage.endEditing()
        syncDraftContent()
    }

    private func convertMarkdownListTrigger(in paragraphRange: NSRange, ordered: Bool) {
        guard let storage = textView.textStorage else { return }
        let nsString = textView.string as NSString
        let paragraph = nsString.substring(with: paragraphRange).replacingOccurrences(of: "\n", with: "")
        guard paragraph.isEmpty == false else { return }

        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: paragraphRange.location, length: paragraph.count),
            with: ""
        )
        storage.endEditing()

        let style = paragraphStyle(at: max(paragraphRange.location - 1, 0)).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)]
        style.firstLineHeadIndent = 26
        style.headIndent = 26
        style.tabStops = [NSTextTab(textAlignment: .left, location: 26, options: [:])]

        var typingAttributes = textView.typingAttributes
        typingAttributes[.paragraphStyle] = style
        textView.typingAttributes = typingAttributes
        textView.setSelectedRange(NSRange(location: paragraphRange.location, length: 0))
        syncDraftContent()
    }

    private func paragraphRanges(for selection: NSRange, in nsString: NSString) -> [NSRange] {
        if nsString.length == 0 {
            return [NSRange(location: 0, length: 0)]
        }

        let safeLocation = min(selection.location, max(nsString.length - 1, 0))
        let effectiveSelection = selection.length == 0
            ? NSRange(location: safeLocation, length: 0)
            : NSRange(location: safeLocation, length: selection.length)

        var ranges: [NSRange] = []
        var cursor = effectiveSelection.location
        let end = effectiveSelection.location + effectiveSelection.length

        repeat {
            let paragraphRange = nsString.paragraphRange(for: NSRange(location: min(cursor, max(nsString.length - 1, 0)), length: 0))
            ranges.append(paragraphRange)
            cursor = paragraphRange.upperBound
        } while cursor < end

        return ranges
    }

    private func paragraphStyle(at location: Int) -> NSParagraphStyle {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return Self.defaultParagraphStyle()
        }
        let safeLocation = min(max(location, 0), storage.length - 1)
        return (storage.attribute(.paragraphStyle, at: safeLocation, effectiveRange: nil) as? NSParagraphStyle)
            ?? Self.defaultParagraphStyle()
    }

    private func allRunsMatch(
        in range: NSRange,
        attribute: NSAttributedString.Key,
        predicate: (Any?) -> Bool
    ) -> Bool {
        guard let storage = textView.textStorage else { return false }
        var matches = true
        storage.enumerateAttribute(attribute, in: range) { value, _, stop in
            if predicate(value) == false {
                matches = false
                stop.pointee = true
            }
        }
        return matches
    }

    private func toggledFont(from font: NSFont, trait: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        let hasTrait = manager.traits(of: font).contains(trait)
        return updatedFont(from: font, trait: trait, shouldApply: hasTrait == false)
    }

    private func updatedFont(from font: NSFont, trait: NSFontTraitMask, shouldApply: Bool) -> NSFont {
        let manager = NSFontManager.shared
        let converted = shouldApply
            ? manager.convert(font, toHaveTrait: trait)
            : manager.convert(font, toNotHaveTrait: trait)
        return converted == font ? Self.defaultFont : converted
    }

    private static var defaultFont: NSFont {
        .systemFont(ofSize: 14)
    }

    private static func defaultParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 6
        return style
    }

    private static func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: defaultFont,
            .foregroundColor: NSColor(MailDesignTokens.textPrimary),
            .paragraphStyle: defaultParagraphStyle(),
        ]
    }

    private static func selectedTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .backgroundColor: NSColor(MailDesignTokens.accent).withAlphaComponent(0.28),
            .foregroundColor: NSColor(MailDesignTokens.textPrimary),
        ]
    }

    private static func makeAttributedString(plainText: String, htmlText: String?) -> NSMutableAttributedString {
        if let htmlText,
           htmlText.isEmpty == false,
           let data = RichComposeHTMLCodec.wrappedHTMLData(from: htmlText),
           let attributed = try? NSMutableAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ) {
            if attributed.length == 0 {
                return NSMutableAttributedString(string: plainText, attributes: defaultTypingAttributes())
            }
            attributed.beginEditing()
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                if attributes[.font] == nil {
                    attributed.addAttribute(.font, value: defaultFont, range: range)
                }
                attributed.addAttribute(.foregroundColor, value: NSColor(MailDesignTokens.textPrimary), range: range)
                attributed.removeAttribute(.backgroundColor, range: range)
                if attributes[.paragraphStyle] == nil {
                    attributed.addAttribute(.paragraphStyle, value: defaultParagraphStyle(), range: range)
                }
            }
            attributed.endEditing()
            return attributed
        }

        return NSMutableAttributedString(string: plainText, attributes: defaultTypingAttributes())
    }

    private static func serializedHTML(from attributedString: NSAttributedString) -> String? {
        guard attributedString.string.isEmpty == false else { return nil }
        guard let data = try? attributedString.data(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func normalizeTypingAttributes() {
        var typingAttributes = textView.typingAttributes
        typingAttributes[.foregroundColor] = NSColor(MailDesignTokens.textPrimary)
        typingAttributes[.backgroundColor] = NSColor.clear
        textView.typingAttributes = typingAttributes
    }
}

final class ComposeRichTextView: NSTextView {
    weak var owner: RichComposeEditorContainer?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command],
           let key = event.charactersIgnoringModifiers?.lowercased(),
           owner?.handleCommandShortcut(key) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)

        if let insertedText = insertString as? String {
            owner?.handleInsertedText(insertedText)
        } else if let inserted = insertString as? NSAttributedString {
            owner?.handleInsertedText(inserted.string)
        }
    }
}

private final class ComposeSelectionToolbarView: NSVisualEffectView {
    weak var editor: RichComposeEditorContainer?

    private let boldButton = ComposeToolbarButton(symbolName: "bold")
    private let italicButton = ComposeToolbarButton(symbolName: "italic")
    private let underlineButton = ComposeToolbarButton(symbolName: "underline")
    private let bulletButton = ComposeToolbarButton(symbolName: "list.bullet")
    private let numberButton = ComposeToolbarButton(symbolName: "list.number")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateState(from textView: NSTextView) {
        let selection = textView.selectedRange()
        let typingAttributes = selection.length == 0 ? textView.typingAttributes : textView.textStorage?.attributes(at: selection.location, effectiveRange: nil) ?? [:]

        if let font = typingAttributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            boldButton.isSelected = traits.contains(.boldFontMask)
            italicButton.isSelected = traits.contains(.italicFontMask)
        } else {
            boldButton.isSelected = false
            italicButton.isSelected = false
        }

        underlineButton.isSelected = ((typingAttributes[.underlineStyle] as? Int) ?? 0) != 0

        let paragraphStyle = (typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? NSParagraphStyle.default
        bulletButton.isSelected = paragraphStyle.textLists.contains { $0.markerFormat == .disc }
        numberButton.isSelected = paragraphStyle.textLists.contains { $0.markerFormat == .decimal }
    }

    private func setup() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let stack = NSStackView(views: [boldButton, italicButton, underlineButton, bulletButton, numberButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        boldButton.target = self
        boldButton.action = #selector(toggleBold)
        italicButton.target = self
        italicButton.action = #selector(toggleItalic)
        underlineButton.target = self
        underlineButton.action = #selector(toggleUnderline)
        bulletButton.target = self
        bulletButton.action = #selector(toggleBullets)
        numberButton.target = self
        numberButton.action = #selector(toggleNumbers)
    }

    @objc private func toggleBold() {
        editor?.toggleBold()
    }

    @objc private func toggleItalic() {
        editor?.toggleItalic()
    }

    @objc private func toggleUnderline() {
        editor?.toggleUnderline()
    }

    @objc private func toggleBullets() {
        editor?.toggleUnorderedList()
    }

    @objc private func toggleNumbers() {
        editor?.toggleOrderedList()
    }
}

private final class ComposeToolbarButton: NSButton {
    var isSelected = false {
        didSet {
            needsDisplay = true
        }
    }

    init(symbolName: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        super.init(frame: .zero)
        self.image = image
        isBordered = false
        imagePosition = .imageOnly
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 7
        contentTintColor = NSColor(MailDesignTokens.textPrimary)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = (isSelected ? NSColor(MailDesignTokens.selected) : .clear).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = (isSelected ? NSColor(MailDesignTokens.selected) : .clear).cgColor
        super.draw(dirtyRect)
    }
}

private enum RichComposeHTMLCodec {
    static func wrappedHTMLData(from html: String) -> Data? {
        let fragment = bodyFragment(from: html) ?? html
        let document = """
        <html>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; font-size: 14px; color: #1a1c24;">
        \(fragment)
        </body>
        </html>
        """
        return document.data(using: .utf8)
    }

    static func bodyFragment(from html: String) -> String? {
        let pattern = "(?is)<body\\b[^>]*>(.*)</body>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let bodyRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

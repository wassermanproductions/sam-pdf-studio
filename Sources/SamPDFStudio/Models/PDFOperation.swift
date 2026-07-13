import Foundation

enum PDFOperation: String, CaseIterable, Identifiable {
    case read
    case annotate
    case fillSign
    case edit
    case redline
    case pages
    case scanOCR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: "Read"
        case .annotate: "Annotate"
        case .fillSign: "Fill & Sign"
        case .edit: "Edit"
        case .redline: "Redline"
        case .pages: "Pages"
        case .scanOCR: "OCR"
        }
    }

    var systemImage: String {
        switch self {
        case .read: "book"
        case .annotate: "highlighter"
        case .fillSign: "signature"
        case .edit: "text.cursor"
        case .redline: "pencil.line"
        case .pages: "square.grid.2x2"
        case .scanOCR: "text.viewfinder"
        }
    }
}

enum FillSignTool: String, CaseIterable, Identifiable {
    case text
    case check
    case cross
    case dot
    case date
    case signature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .check: "Check"
        case .cross: "Cross"
        case .dot: "Dot"
        case .date: "Date"
        case .signature: "Sign"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "character.textbox"
        case .check: "checkmark"
        case .cross: "xmark"
        case .dot: "circle.fill"
        case .date: "calendar"
        case .signature: "signature"
        }
    }
}

enum RedlineTool: String, CaseIterable, Identifiable {
    case strikeout
    case squiggly
    case insert
    case replace
    case note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strikeout: "Strikeout"
        case .squiggly: "Squiggly"
        case .insert: "Insert"
        case .replace: "Replace"
        case .note: "Note"
        }
    }

    var systemImage: String {
        switch self {
        case .strikeout: "strikethrough"
        case .squiggly: "scribble"
        case .insert: "text.insert"
        case .replace: "arrow.triangle.2.circlepath"
        case .note: "note.text"
        }
    }
}

enum AnnotateTool: String, CaseIterable, Identifiable {
    case highlight
    case underline
    case strikeout
    case note
    case textBox
    case signature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeout: "Strikeout"
        case .note: "Note"
        case .textBox: "Text"
        case .signature: "Sign"
        }
    }

    var systemImage: String {
        switch self {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeout: "strikethrough"
        case .note: "note.text"
        case .textBox: "character.textbox"
        case .signature: "signature"
        }
    }

    var placesByClick: Bool {
        switch self {
        case .note, .textBox, .signature: true
        case .highlight, .underline, .strikeout: false
        }
    }
}

enum EditTool: String, CaseIterable, Identifiable {
    case contentText
    case grab
    case image
    case link
    case redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contentText: "Text"
        case .grab: "Grab"
        case .image: "Image"
        case .link: "Link"
        case .redact: "Redact"
        }
    }

    var systemImage: String {
        switch self {
        case .contentText: "text.cursor"
        case .grab: "lasso"
        case .image: "photo"
        case .link: "link"
        case .redact: "eye.slash"
        }
    }

    var help: String {
        switch self {
        case .contentText: "Click a paragraph to select it · drag anywhere to move · click again to type"
        case .grab: "Drag to lasso a region, then copy, paste, or move it"
        case .image: "Choose an image, then click the page to place it"
        case .link: "Drag over an area, then enter the link address"
        case .redact: "Select text, then click Redact to remove it permanently"
        }
    }
}

enum AnnotationKind: String, CaseIterable, Identifiable {
    case highlight
    case underline
    case strikeout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeout: "Strikeout"
        }
    }
}

enum TextExportFormat: String, CaseIterable, Identifiable {
    case text = "txt"
    case markdown = "md"
    case html = "html"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .markdown: "Markdown"
        case .html: "HTML"
        }
    }
}

enum ImageExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpg

    var id: String { rawValue }

    var title: String { rawValue.uppercased() }
}

enum OfficeExportFormat: String, CaseIterable, Identifiable {
    case word = "docx"
    case excel = "xlsx"
    case powerpoint = "pptx"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .word: "Word"
        case .excel: "Excel"
        case .powerpoint: "PowerPoint"
        }
    }
}

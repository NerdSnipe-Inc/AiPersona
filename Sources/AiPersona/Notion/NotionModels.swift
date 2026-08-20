import Foundation

/// One active fact, shaped for a Notion database row. Fixed schema (name, kind, fact, valid-from)
/// rather than synapse-cortex's Gemini-designed dynamic per-graph schema — a fixed schema is the
/// right starting point here. `needsReview`/`correctionNotes` are the feedback-loop columns a
/// user edits in Notion to trigger a correction on import.
public struct NotionExportRow: Equatable, Sendable {
    public let subjectName: String
    public let kind: String
    public let factText: String
    public let validFrom: Date
    public let needsReview: Bool
    public let correctionNotes: String

    public init(
        subjectName: String, kind: String, factText: String, validFrom: Date,
        needsReview: Bool = false, correctionNotes: String = ""
    ) {
        self.subjectName = subjectName
        self.kind = kind
        self.factText = factText
        self.validFrom = validFrom
        self.needsReview = needsReview
        self.correctionNotes = correctionNotes
    }
}

/// A row read back from Notion during correction import: the page to update/clear afterward, and
/// the free-text correction a user wrote in the "Correction Notes" column.
public struct NotionCorrectionRow: Equatable, Sendable {
    public let pageID: String
    public let subjectName: String
    public let correctionNotes: String

    public init(pageID: String, subjectName: String, correctionNotes: String) {
        self.pageID = pageID
        self.subjectName = subjectName
        self.correctionNotes = correctionNotes
    }
}

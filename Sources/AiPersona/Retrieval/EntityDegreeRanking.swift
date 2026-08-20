import Foundation

/// Degree-based ranking — synapse-cortex's "degree-based filtering" (README core feature 1),
/// used to favor well-connected entities when the active-fact pool exceeds the session
/// compilation's budget. Degree here means "how many active facts touch this entity as subject
/// or object" — a cheap, purely local proxy for the confidence signal synapse-cortex derives
/// server-side; an entity mentioned once in passing is less likely to be durably important than
/// one tied into many facts.
public enum EntityDegreeRanking {
    /// Counts, for every entity ID referenced by `activeFacts`, how many of those facts touch it
    /// as subject or object.
    public static func degrees(forActiveFacts activeFacts: [FactEdge]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for fact in activeFacts {
            counts[fact.subjectID, default: 0] += 1
            if let objectID = fact.objectID {
                counts[objectID, default: 0] += 1
            }
        }
        return counts
    }

    /// Sorts `facts` by their subject entity's degree (descending), breaking ties by recency
    /// (`validAt` descending) — the same ordering `sessionCompilation()` used before degree
    /// ranking existed, so the common case of one subject entity with many facts (all sharing
    /// the same degree) still favors recency exactly as before.
    public static func rank(_ facts: [FactEdge], byDegrees degrees: [UUID: Int]) -> [FactEdge] {
        facts.sorted { lhs, rhs in
            let lhsDegree = degrees[lhs.subjectID] ?? 0
            let rhsDegree = degrees[rhs.subjectID] ?? 0
            if lhsDegree != rhsDegree { return lhsDegree > rhsDegree }
            return lhs.validAt > rhs.validAt
        }
    }
}

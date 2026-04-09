import Foundation

// MARK: - Future Shell Primitive Types
// 17 type families covering all 20 design primitives.
// The runtime store that manages these lives in FutureRuntime.swift.

// MARK: - 1. Artifact Envelopes

public enum ArtifactKind: String, Codable, Sendable {
    case text, code, markdown, image, binary, diff, symbolGraph, trace, intent, plan, proof, repoDiff, config, metric, log
}

public struct Provenance: Codable, Sendable {
    public let sourceCommand: String?
    public let sourceFile: String?
    public let traceId: String?
    public let timestamp: Date
    public let confidence: Double
    public let method: String
}

public struct ArtifactEnvelope: Codable, Sendable {
    public let id: String
    public let kind: ArtifactKind
    public let label: String
    public let content: String
    public let contentHash: String
    public let provenance: Provenance
    public let createdAt: Date
    public let tags: [String]
    public let policyTags: [String]
}

// MARK: - 2. Intent Contracts

public enum IntentStatus: String, Codable, Sendable {
    case declared, active, satisfied, failed, abandoned
}

public enum RiskLevel: String, Codable, Sendable {
    case low, medium, high, critical
}

public struct IntentContract: Codable, Sendable {
    public let id: String
    public let statement: String
    public let reason: String?
    public let mutations: [String]
    public let successCriteria: String?
    public let riskLevel: RiskLevel
    public let verification: String?
    public let createdAt: Date
    public var status: IntentStatus
}

// MARK: - 3. Capability Leases

public struct CapabilityLease: Codable, Sendable {
    public let id: String
    public let capability: String
    public let resource: String
    public let grantee: String
    public let actions: [String]
    public let grantedAt: Date
    public let expiresAt: Date
    public var revoked: Bool
}

// MARK: - 4. Simulation Reports

public struct PredictedEffect: Codable, Sendable {
    public let kind: String
    public let target: String
    public let reversible: Bool
    public let description: String
}

public struct SimulationReport: Codable, Sendable {
    public let id: String
    public let command: String
    public let predictedStatus: Int32
    public let predictedStdout: String
    public let predictedEffects: [PredictedEffect]
    public let riskAssessment: RiskLevel
    public let rollbackPath: String?
    public let confidence: Double
    public let alternatives: [String]
    public let simulatedAt: Date
}

// MARK: - 5. Proof Envelopes

public struct EvidenceItem: Codable, Sendable {
    public let kind: String
    public let source: String
    public let value: String
    public let verified: Bool
}

public struct ProofEnvelope: Codable, Sendable {
    public let id: String
    public let claim: String
    public let evidence: [EvidenceItem]
    public let confidence: Double
    public let validatedAt: Date
    public let traceId: String?
    public let replayToken: String?
}

// MARK: - 6. Entity Handles

public struct EntityView: Codable, Sendable {
    public let modality: String
    public let value: String
}

public struct EntityHandle: Codable, Sendable {
    public let id: String
    public let label: String
    public let kind: String
    public let views: [EntityView]
    public let createdAt: Date
    public let lastAccessed: Date
}

// MARK: - 7. Semantic Diffs

public struct SemanticDiff: Codable, Sendable {
    public let id: String
    public let kind: String
    public let summary: String
    public let before: String
    public let after: String
    public let preservesBehavior: Bool?
    public let breakingChanges: [String]
    public let createdAt: Date
}

// MARK: - 8. World Graph

public struct WorldEdge: Codable, Sendable {
    public let relation: String
    public let targetId: String
    public let weight: Double
}

public struct WorldNode: Codable, Sendable {
    public let id: String
    public let kind: String
    public let label: String
    public let properties: [String: String]
    public let edges: [WorldEdge]
}

// MARK: - 9. Tool Contracts

public struct ToolContract: Codable, Sendable {
    public let name: String
    public let accepts: [String]
    public let mutates: [String]
    public let guarantees: [String]
    public let failureModes: [String]
    public let cost: String
    public let latency: String
    public let trust: String
    public let reversible: Bool
    public let offlineCapable: Bool
}

// MARK: - 10. Attention Events

public enum AttentionPriority: String, Codable, Sendable, Comparable {
    case urgent, important, normal, ignorable, deferrable

    private var rank: Int {
        switch self {
        case .urgent: return 4
        case .important: return 3
        case .normal: return 2
        case .ignorable: return 1
        case .deferrable: return 0
        }
    }

    public static func < (lhs: AttentionPriority, rhs: AttentionPriority) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct AttentionEvent: Codable, Sendable {
    public let id: String
    public let priority: AttentionPriority
    public let source: String
    public let summary: String
    public let detail: String?
    public let createdAt: Date
    public let expiresAt: Date?
    public var acknowledged: Bool
}

// MARK: - 11. Policy Envelopes

public struct PolicyRule: Codable, Sendable {
    public let domain: String
    public let constraint: String
    public let enforcement: String
}

public struct PolicyEnvelope: Codable, Sendable {
    public let id: String
    public let rules: [PolicyRule]
    public let activeSince: Date
}

// MARK: - 12. Delegation Tickets

public enum DelegationStatus: String, Codable, Sendable {
    case pending, active, completed, failed, conflicted
}

public struct DelegationTicket: Codable, Sendable {
    public let id: String
    public let delegatee: String
    public let task: String
    public let ownership: String
    public let mergeRule: String
    public let leaseIds: [String]
    public let createdAt: Date
    public var status: DelegationStatus
}

// MARK: - 13. Cognitive Packets

public struct CognitivePacket: Codable, Sendable {
    public let id: String
    public let format: String
    public let state: [String: String]
    public let decisions: [String]
    public let invariants: [String]
    public let createdAt: Date
    public let compressedFrom: Int
}

// MARK: - 14. Time Specs

public struct RetryPolicy: Codable, Sendable {
    public let maxAttempts: Int
    public let backoffSec: Double
    public let strategy: String
}

public struct TimeSpec: Codable, Sendable {
    public let urgency: String
    public let durability: String
    public let retryPolicy: RetryPolicy?
    public let observationWindowSec: Int?
    public let expiresAt: Date?
}

// MARK: - 15. Uncertainty Surfaces

public enum EpistemicStatus: String, Codable, Sendable {
    case known, inferred, guessed, stale, contradicted
}

public struct UncertaintyEntry: Codable, Sendable {
    public let claim: String
    public let status: EpistemicStatus
    public let confidence: Double
    public let basis: String
    public let lastVerified: Date?
}

public struct UncertaintySurface: Codable, Sendable {
    public let id: String
    public let subject: String
    public let entries: [UncertaintyEntry]
    public let createdAt: Date
}

// MARK: - 16. Repair Plans

public struct RepairOption: Codable, Sendable {
    public let action: String
    public let rationale: String
    public let risk: RiskLevel
    public let command: String?
}

public struct RepairPlan: Codable, Sendable {
    public let id: String
    public let failedCommand: String
    public let exitStatus: Int32
    public let errorSummary: String
    public let rootCauses: [String]
    public let repairOptions: [RepairOption]
    public let safeRetryPlan: String?
    public let createdAt: Date
}

// MARK: - 17. Multimodal Joins

public struct JoinView: Codable, Sendable {
    public let modality: String
    public let source: String
    public let content: String
    public let timestamp: Date?
}

public struct MultimodalJoin: Codable, Sendable {
    public let id: String
    public let anchor: String
    public let views: [JoinView]
    public let createdAt: Date
}

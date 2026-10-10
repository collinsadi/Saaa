import Foundation

/// Token and cost totals for one (role, model) pair. Plain numbers so
/// persistence needs no API types.
public struct UsageRecord: Sendable, Codable, Equatable, Hashable {
    public var role: String
    public var model: String
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var costUSD: Double

    public init(
        role: String, model: String, requests: Int = 1, inputTokens: Int = 0, outputTokens: Int = 0,
        cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, costUSD: Double = 0
    ) {
        self.role = role
        self.model = model
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
    }
}

/// All usage for a session (or a month), merged by role and model.
public struct UsageLedger: Sendable, Codable, Equatable {
    public private(set) var records: [UsageRecord]

    public init(records: [UsageRecord] = []) {
        self.records = []
        for record in records { add(record) }
    }

    public mutating func add(_ record: UsageRecord) {
        if let index = records.firstIndex(where: { $0.role == record.role && $0.model == record.model }) {
            records[index].requests += record.requests
            records[index].inputTokens += record.inputTokens
            records[index].outputTokens += record.outputTokens
            records[index].cacheReadTokens += record.cacheReadTokens
            records[index].cacheWriteTokens += record.cacheWriteTokens
            records[index].costUSD += record.costUSD
        } else {
            records.append(record)
        }
    }

    public mutating func merge(_ other: UsageLedger) {
        for record in other.records { add(record) }
    }

    public var totalCostUSD: Double { records.reduce(0) { $0 + $1.costUSD } }
    public var totalRequests: Int { records.reduce(0) { $0 + $1.requests } }
    public var totalTokens: Int {
        records.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
    }

    /// Share of prompt tokens served from cache.
    public var cacheHitRatio: Double {
        let read = records.reduce(0) { $0 + $1.cacheReadTokens }
        let prompt = records.reduce(0) { $0 + $1.inputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
        return prompt > 0 ? Double(read) / Double(prompt) : 0
    }

    /// "$0.04" / "<$0.01".
    public static func format(_ dollars: Double) -> String {
        if dollars <= 0 { return "$0.00" }
        if dollars < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", dollars)
    }
}

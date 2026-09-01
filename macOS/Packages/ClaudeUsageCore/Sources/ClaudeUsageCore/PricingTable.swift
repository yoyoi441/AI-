import Foundation

public struct ModelPricing: Sendable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheWritePerMillion: Double
    public let cacheReadPerMillion: Double

    public init(inputPerMillion: Double, outputPerMillion: Double, cacheWritePerMillion: Double, cacheReadPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
    }
}

/// Approximate USD-per-1M-token pricing, used only for the "estimated cost" display.
///
/// NOTE: these numbers can go stale — Anthropic can change pricing at any time, and
/// this table was filled in from the best information available while building this
/// app, not fetched live. Verify against https://anthropic.com/pricing and update the
/// entries below if they drift. Models not listed here are simply excluded from cost
/// totals (never silently priced at $0).
public enum PricingTable {
    public static let byModel: [String: ModelPricing] = [
        "claude-opus-5": ModelPricing(inputPerMillion: 15, outputPerMillion: 75, cacheWritePerMillion: 18.75, cacheReadPerMillion: 1.5),
        "claude-sonnet-5": ModelPricing(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3),
        "claude-haiku-4-5-20251001": ModelPricing(inputPerMillion: 1, outputPerMillion: 5, cacheWritePerMillion: 1.25, cacheReadPerMillion: 0.1),
    ]

    public static func estimatedCostUSD(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) -> Double? {
        guard let pricing = byModel[model] else { return nil }
        return Double(inputTokens) / 1_000_000 * pricing.inputPerMillion
            + Double(outputTokens) / 1_000_000 * pricing.outputPerMillion
            + Double(cacheCreationTokens) / 1_000_000 * pricing.cacheWritePerMillion
            + Double(cacheReadTokens) / 1_000_000 * pricing.cacheReadPerMillion
    }
}

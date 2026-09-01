using System.Collections.Generic;

namespace TokenMihariban.Models;

public sealed record ModelPricing(double InputPerMillion, double OutputPerMillion, double CacheWritePerMillion, double CacheReadPerMillion);

/// <summary>
/// Approximate USD-per-1M-token pricing, used only for the "estimated cost" display.
/// NOTE: these numbers can go stale — verify against https://anthropic.com/pricing.
/// Models not listed here are simply excluded from cost totals (never silently priced at $0).
/// </summary>
public static class PricingTable
{
    public static readonly Dictionary<string, ModelPricing> ByModel = new()
    {
        ["claude-opus-5"] = new ModelPricing(15, 75, 18.75, 1.5),
        ["claude-sonnet-5"] = new ModelPricing(3, 15, 3.75, 0.3),
        ["claude-haiku-4-5-20251001"] = new ModelPricing(1, 5, 1.25, 0.1),
    };

    public static double? EstimatedCostUSD(string model, long inputTokens, long outputTokens, long cacheCreationTokens, long cacheReadTokens)
    {
        if (!ByModel.TryGetValue(model, out var pricing)) return null;
        return inputTokens / 1_000_000.0 * pricing.InputPerMillion
            + outputTokens / 1_000_000.0 * pricing.OutputPerMillion
            + cacheCreationTokens / 1_000_000.0 * pricing.CacheWritePerMillion
            + cacheReadTokens / 1_000_000.0 * pricing.CacheReadPerMillion;
    }
}

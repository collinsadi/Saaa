package main

// Prices per million tokens in US dollars, the same table as the app's
// ModelCatalog (AnthropicKit). Unknown models are priced as Sonnet so the
// meter never under-counts.
type modelPrice struct {
	input, output, cacheWrite5m, cacheWrite1h, cacheRead float64
	// Prompts above this many tokens bill every category at the multiplier.
	longContextThreshold  int64
	longContextMultiplier float64
}

var prices = map[string]modelPrice{
	"claude-haiku-5-5":  {input: 0.10, output: 0.50, cacheWrite5m: 0.125, cacheWrite1h: 0.20, cacheRead: 0.01, longContextThreshold: 100_000, longContextMultiplier: 5},
	"claude-sonnet-5-5": {input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.10},
	"claude-opus-5-5":   {input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.20},
}

const fallbackModel = "claude-sonnet-5-5"

// costMicros is one request's cost in millionths of a dollar. Dollars per
// million tokens times tokens is exactly micro-dollars.
func costMicros(model string, u Usage) int64 {
	price, ok := prices[model]
	if !ok {
		price = prices[fallbackModel]
	}
	multiplier := 1.0
	prompt := u.InputTokens + u.CacheReadTokens + u.CacheWrite5mTokens + u.CacheWrite1hTokens
	if price.longContextThreshold > 0 && prompt > price.longContextThreshold {
		multiplier = price.longContextMultiplier
	}
	micros := float64(u.InputTokens)*price.input +
		float64(u.OutputTokens)*price.output +
		float64(u.CacheWrite5mTokens)*price.cacheWrite5m +
		float64(u.CacheWrite1hTokens)*price.cacheWrite1h +
		float64(u.CacheReadTokens)*price.cacheRead
	return int64(micros*multiplier + 0.5)
}

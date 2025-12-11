/**
 * ============================================================================
 * SENTIMENT FEE HOOK - MULTI-SOURCE KEEPER
 * ============================================================================
 *
 * Off-chain keeper bot that aggregates market sentiment from 8 free data
 * sources and updates the SentimentFeeHook contract on-chain.
 *
 * Features:
 * - Weighted aggregation from 8 free APIs
 * - Anti-frontrunning with randomized timing jitter
 * - Rate limiting and graceful degradation
 * - Configurable update thresholds
 *
 * Data Sources (by weight):
 * - Fear & Greed Index (30%) - Direct sentiment measure
 * - CoinGecko Global (20%) - 24h market cap change
 * - CoinGecko Trending (10%) - Trending coin momentum
 * - BTC Dominance (10%) - Flight to safety indicator
 * - DeFi Llama TVL (10%) - Total value locked change
 * - ETH Price Change (10%) - ETH 24h movement
 * - CryptoCompare Social (5%) - Reddit activity
 * - Blockchain.com Stats (5%) - Bitcoin tx count
 *
 * @author Sentiment Finance
 * @version 1.0.0
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";

dotenv.config();

// ============================================================================
// TYPES & INTERFACES
// ============================================================================

/**
 * Represents a single sentiment data source
 */
interface SentimentSource {
  /** Human-readable name for logging */
  name: string;
  /** Weight in percentage (all weights should sum to 100) */
  weight: number;
  /** Async function that fetches and normalizes the score (0-100) */
  fetch: () => Promise<number>;
}

/**
 * Result of fetching from a single source
 */
interface FetchResult {
  source: SentimentSource;
  score: number;
  success: boolean;
}

/**
 * Configuration loaded from environment variables
 */
interface KeeperConfig {
  rpcUrl: string;
  privateKey: string;
  hookAddress: string;
  updateInterval: number;
  minChangeThreshold: number;
  jitterMinutes: number;
}

// ============================================================================
// CONTRACT ABI (MINIMAL)
// ============================================================================

const HOOK_ABI = [
  "function updateSentiment(uint8 _rawScore) external",
  "function sentimentScore() external view returns (uint8)",
  "function isStale() external view returns (bool)",
  "function primaryKeeper() external view returns (address)",
  "function isAuthorizedKeeper(address) external view returns (bool)",
];

// ============================================================================
// CONFIGURATION
// ============================================================================

/**
 * Validates and loads configuration from environment variables
 * @throws Error if required variables are missing
 */
function loadConfig(): KeeperConfig {
  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY;
  const hookAddress = process.env.HOOK_ADDRESS;

  if (!rpcUrl) {
    throw new Error("Missing RPC_URL environment variable");
  }
  if (!privateKey) {
    throw new Error("Missing PRIVATE_KEY environment variable");
  }
  if (!hookAddress) {
    throw new Error("Missing HOOK_ADDRESS environment variable");
  }

  return {
    rpcUrl,
    privateKey,
    hookAddress,
    updateInterval: parseInt(process.env.UPDATE_INTERVAL || "14400000"), // 4 hours
    minChangeThreshold: parseInt(process.env.MIN_CHANGE_THRESHOLD || "5"),
    jitterMinutes: parseInt(process.env.JITTER_MINUTES || "30"),
  };
}

// ============================================================================
// DATA SOURCE IMPLEMENTATIONS
// ============================================================================

/**
 * Maps a value from one range to another
 * @param value - Input value
 * @param inMin - Input range minimum
 * @param inMax - Input range maximum
 * @param outMin - Output range minimum (default: 0)
 * @param outMax - Output range maximum (default: 100)
 */
function mapRange(
  value: number,
  inMin: number,
  inMax: number,
  outMin: number = 0,
  outMax: number = 100
): number {
  const mapped = ((value - inMin) / (inMax - inMin)) * (outMax - outMin) + outMin;
  return Math.min(outMax, Math.max(outMin, mapped));
}

/**
 * Source 1: Fear & Greed Index (alternative.me)
 * - FREE, no rate limits
 * - Direct sentiment measure (0-100)
 * - Most reliable single indicator
 */
async function fetchFearGreedIndex(): Promise<number> {
  const response = await fetch("https://api.alternative.me/fng/?limit=1");
  const data = (await response.json()) as any;
  const score = parseInt(data.data[0].value);
  const classification = data.data[0].value_classification;

  console.log(`  Fear & Greed Index: ${score} (${classification})`);
  return score;
}

/**
 * Source 2: CoinGecko Global Market Data
 * - FREE tier: 30 calls/min
 * - Maps 24h market cap change to sentiment
 * - Range: -10% to +10% -> 0-100
 */
async function fetchCoinGeckoGlobal(): Promise<number> {
  const response = await fetch("https://api.coingecko.com/api/v3/global");
  const data = (await response.json()) as any;
  const change = data.data.market_cap_change_percentage_24h_usd;
  const score = mapRange(change, -10, 10);

  console.log(`  CoinGecko 24h Market Change: ${change.toFixed(2)}% -> ${Math.round(score)}`);
  return Math.round(score);
}

/**
 * Source 3: CoinGecko Trending Coins
 * - FREE, included in rate limit
 * - More coins with positive price change = higher sentiment
 */
async function fetchCoinGeckoTrending(): Promise<number> {
  const response = await fetch("https://api.coingecko.com/api/v3/search/trending");
  const data = (await response.json()) as any;

  const coins = data.coins?.slice(0, 7) || [];
  let positiveCount = 0;

  for (const coin of coins) {
    const priceChange = coin.item?.data?.price_change_percentage_24h?.usd || 0;
    if (priceChange > 0) positiveCount++;
  }

  const score = Math.round((positiveCount / 7) * 100);
  console.log(`  CoinGecko Trending: ${positiveCount}/7 positive -> ${score}`);
  return score;
}

/**
 * Source 4: Bitcoin Dominance (inverse indicator)
 * - FREE, uses global endpoint
 * - High BTC dominance = fear (flight to safety)
 * - Low BTC dominance = greed (altcoin season)
 * - Range: 60% -> 0, 35% -> 100
 */
async function fetchBTCDominance(): Promise<number> {
  const response = await fetch("https://api.coingecko.com/api/v3/global");
  const data = (await response.json()) as any;
  const dominance = data.data.market_cap_percentage.btc;
  const score = mapRange(dominance, 60, 35); // Inverted: higher dominance = lower score

  console.log(`  BTC Dominance: ${dominance.toFixed(1)}% -> ${Math.round(score)}`);
  return Math.round(score);
}

/**
 * Source 5: DeFi Llama Total Value Locked
 * - FREE, no rate limits
 * - Maps TVL 24h change to sentiment
 * - Range: -5% to +5% -> 0-100
 */
async function fetchDefiLlamaTVL(): Promise<number> {
  const response = await fetch("https://api.llama.fi/v2/historicalChainTvl");
  const data = (await response.json()) as any[];

  if (data.length < 2) {
    throw new Error("Insufficient TVL data");
  }

  const latest = data[data.length - 1].tvl;
  const dayAgo = data[data.length - 2].tvl;
  const change = ((latest - dayAgo) / dayAgo) * 100;
  const score = mapRange(change, -5, 5);

  console.log(`  DeFi Llama TVL Change: ${change.toFixed(2)}% -> ${Math.round(score)}`);
  return Math.round(score);
}

/**
 * Source 6: ETH Price Movement
 * - FREE, uses CoinGecko simple price
 * - Maps ETH 24h change to sentiment
 * - Range: -10% to +10% -> 0-100
 */
async function fetchETHPriceChange(): Promise<number> {
  const response = await fetch(
    "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd&include_24hr_change=true"
  );
  const data = (await response.json()) as any;
  const change = data.ethereum.usd_24h_change;
  const score = mapRange(change, -10, 10);

  console.log(`  ETH 24h Change: ${change.toFixed(2)}% -> ${Math.round(score)}`);
  return Math.round(score);
}

/**
 * Source 7: CryptoCompare Social Stats
 * - FREE tier available
 * - Uses Reddit active users as sentiment proxy
 * - Normalized around 5000 active users
 */
async function fetchCryptoCompareSocial(): Promise<number> {
  const response = await fetch(
    "https://min-api.cryptocompare.com/data/social/coin/latest?coinId=1182"
  );
  const data = (await response.json()) as any;
  const activeUsers = data.Data?.Reddit?.active_users || 0;
  const score = Math.min(100, Math.max(0, activeUsers / 100));

  console.log(`  CryptoCompare Reddit Active: ${activeUsers} -> ${Math.round(score)}`);
  return Math.round(score);
}

/**
 * Source 8: Blockchain.com Network Stats
 * - FREE, no auth required
 * - Uses Bitcoin transaction count as activity indicator
 * - Normalized around 300k tx/day
 */
async function fetchBlockchainStats(): Promise<number> {
  const response = await fetch("https://api.blockchain.info/stats");
  const data = (await response.json()) as any;
  const txCount = data.n_tx || 0;
  const score = Math.min(100, Math.max(0, (txCount / 300000) * 50));

  console.log(`  Blockchain.com TX Count: ${txCount} -> ${Math.round(score)}`);
  return Math.round(score);
}

// ============================================================================
// SOURCE REGISTRY
// ============================================================================

/**
 * All sentiment sources with their weights (must sum to 100)
 */
const SENTIMENT_SOURCES: SentimentSource[] = [
  { name: "Fear & Greed Index", weight: 30, fetch: fetchFearGreedIndex },
  { name: "CoinGecko Global", weight: 20, fetch: fetchCoinGeckoGlobal },
  { name: "CoinGecko Trending", weight: 10, fetch: fetchCoinGeckoTrending },
  { name: "BTC Dominance", weight: 10, fetch: fetchBTCDominance },
  { name: "DeFi Llama TVL", weight: 10, fetch: fetchDefiLlamaTVL },
  { name: "ETH Price Change", weight: 10, fetch: fetchETHPriceChange },
  { name: "CryptoCompare Social", weight: 5, fetch: fetchCryptoCompareSocial },
  { name: "Blockchain.com Stats", weight: 5, fetch: fetchBlockchainStats },
];

// ============================================================================
// SENTIMENT AGGREGATION
// ============================================================================

/**
 * Fetches and aggregates sentiment from all sources
 *
 * - Gracefully handles individual source failures
 * - Redistributes weights when sources fail
 * - Returns neutral (50) if all sources fail
 *
 * @returns Composite sentiment score (0-100)
 */
async function calculateMultiSourceSentiment(): Promise<number> {
  console.log("\nFetching from all data sources...\n");

  const results: FetchResult[] = [];
  const RATE_LIMIT_DELAY_MS = 200;

  for (const source of SENTIMENT_SOURCES) {
    try {
      const score = await source.fetch();
      results.push({ source, score, success: true });
    } catch (error) {
      console.error(`  ${source.name}: FAILED - ${(error as Error).message}`);
      results.push({ source, score: 0, success: false });
    }

    // Small delay between requests to respect rate limits
    await new Promise((resolve) => setTimeout(resolve, RATE_LIMIT_DELAY_MS));
  }

  // Filter successful results
  const successfulResults = results.filter((r) => r.success);

  if (successfulResults.length === 0) {
    console.log("\nAll sources failed! Returning neutral sentiment (50).");
    return 50;
  }

  // Calculate weighted average from successful sources only
  const totalWeight = successfulResults.reduce((sum, r) => sum + r.source.weight, 0);
  const weightedSum = successfulResults.reduce(
    (sum, r) => sum + r.score * r.source.weight,
    0
  );
  const composite = Math.round(weightedSum / totalWeight);

  // Log summary
  console.log("\n" + "=".repeat(50));
  console.log(`Sources: ${successfulResults.length}/${SENTIMENT_SOURCES.length} successful`);
  console.log(`Effective weight: ${totalWeight}%`);
  console.log(`Composite Sentiment: ${composite}`);
  console.log("=".repeat(50) + "\n");

  return composite;
}

// ============================================================================
// ANTI-FRONTRUNNING: RANDOMIZED JITTER
// ============================================================================

/**
 * Applies random timing delay to prevent frontrunning attacks
 *
 * Attackers monitoring the keeper's wallet could front-run sentiment
 * updates by watching for pending transactions. Random jitter makes
 * the exact update time unpredictable.
 *
 * @param maxMinutes - Maximum jitter in minutes
 */
async function applyRandomJitter(maxMinutes: number): Promise<void> {
  if (maxMinutes <= 0) return;

  const jitterMs = Math.floor(Math.random() * maxMinutes * 60 * 1000);
  const jitterDisplay = (jitterMs / 60000).toFixed(1);

  console.log(`\nAnti-frontrunning: applying ${jitterDisplay} minute random delay...`);

  await new Promise((resolve) => setTimeout(resolve, jitterMs));
}

// ============================================================================
// KEEPER CLASS
// ============================================================================

/**
 * Multi-Source Sentiment Keeper
 *
 * Orchestrates sentiment data collection and on-chain updates.
 * Designed for long-running operation with configurable intervals.
 */
class MultiSourceKeeper {
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;
  private hook: ethers.Contract;
  private config: KeeperConfig;

  constructor(config: KeeperConfig) {
    this.config = config;
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.wallet = new ethers.Wallet(config.privateKey, this.provider);
    this.hook = new ethers.Contract(config.hookAddress, HOOK_ABI, this.wallet);
  }

  /**
   * Logs keeper configuration at startup
   */
  logConfig(): void {
    console.log("\n" + "=".repeat(50));
    console.log("SENTIMENT FEE HOOK - MULTI-SOURCE KEEPER");
    console.log("=".repeat(50));
    console.log(`Hook Address:    ${this.config.hookAddress}`);
    console.log(`Keeper Wallet:   ${this.wallet.address}`);
    console.log(`Update Interval: ${this.config.updateInterval / 60000} minutes`);
    console.log(`Change Threshold: ${this.config.minChangeThreshold}%`);
    console.log(`Timing Jitter:   +/- ${this.config.jitterMinutes} minutes`);
    console.log("=".repeat(50) + "\n");
  }

  /**
   * Verifies the keeper wallet is authorized to update sentiment
   * @throws Error if not authorized
   */
  async verifyAuthorization(): Promise<void> {
    const isAuthorized = await this.hook.isAuthorizedKeeper(this.wallet.address);

    if (!isAuthorized) {
      const primaryKeeper = await this.hook.primaryKeeper();
      throw new Error(
        `Wallet ${this.wallet.address} is not authorized.\n` +
          `Primary keeper is: ${primaryKeeper}`
      );
    }

    console.log("Authorization verified: wallet is an authorized keeper");
  }

  /**
   * Executes a single sentiment update cycle
   *
   * @param skipJitter - If true, skips the random timing delay (for testing)
   */
  async runOnce(skipJitter: boolean = false): Promise<void> {
    console.log("\n" + "=".repeat(50));
    console.log("SENTIMENT UPDATE CYCLE");
    console.log(`Started: ${new Date().toISOString()}`);
    console.log("=".repeat(50));

    // Step 1: Apply anti-frontrunning jitter (unless skipped)
    if (!skipJitter && this.config.jitterMinutes > 0) {
      await applyRandomJitter(this.config.jitterMinutes);
    }

    // Step 2: Verify authorization (may have changed since startup)
    await this.verifyAuthorization();

    // Step 3: Fetch current on-chain state
    const currentSentiment = Number(await this.hook.sentimentScore());
    const isStale = await this.hook.isStale();

    console.log(`\nCurrent on-chain state:`);
    console.log(`  Sentiment Score: ${currentSentiment}`);
    console.log(`  Is Stale: ${isStale}`);

    // Step 4: Calculate new sentiment from all sources
    const newSentiment = await calculateMultiSourceSentiment();

    // Step 5: Decide whether to update
    const change = Math.abs(newSentiment - currentSentiment);

    if (!isStale && change < this.config.minChangeThreshold) {
      console.log(
        `Skipping update: change (${change}) < threshold (${this.config.minChangeThreshold})`
      );
      return;
    }

    // Step 6: Send the update transaction
    console.log(`\nSubmitting update: ${currentSentiment} -> ${newSentiment}`);

    const tx = await this.hook.updateSentiment(newSentiment);
    console.log(`Transaction hash: ${tx.hash}`);

    const receipt = await tx.wait();
    console.log(`Confirmed in block: ${receipt.blockNumber}`);
    console.log(`Gas used: ${receipt.gasUsed.toString()}`);
  }

  /**
   * Starts the keeper in continuous loop mode
   * @param skipJitter - If true, disables timing jitter (for testing)
   */
  async startLoop(skipJitter: boolean = false): Promise<void> {
    this.logConfig();
    await this.verifyAuthorization();

    console.log(`Starting continuous loop...`);
    console.log(
      `Updates will occur every ${this.config.updateInterval / 60000} minutes\n`
    );

    // Run immediately, then on interval
    await this.runOnce(skipJitter);

    setInterval(async () => {
      try {
        await this.runOnce(skipJitter);
      } catch (error) {
        console.error("Update cycle failed:", (error as Error).message);
      }
    }, this.config.updateInterval);
  }
}

// ============================================================================
// MAIN ENTRY POINT
// ============================================================================

async function main(): Promise<void> {
  const config = loadConfig();
  const keeper = new MultiSourceKeeper(config);

  const isOnceMode = process.argv.includes("--once");
  const skipJitter = process.argv.includes("--no-jitter");

  if (isOnceMode) {
    // Single execution mode (for testing or manual runs)
    keeper.logConfig();
    await keeper.runOnce(true); // Always skip jitter in once mode
  } else {
    // Continuous loop mode (production)
    await keeper.startLoop(skipJitter);
  }
}

main().catch((error) => {
  console.error("\nFATAL ERROR:", error.message);
  process.exit(1);
});

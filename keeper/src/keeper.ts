import { ethers } from "ethers";
import * as dotenv from "dotenv";

dotenv.config();

// SentimentFeeHook ABI (only what we need)
const HOOK_ABI = [
  "function updateSentiment(uint8 _rawScore) external",
  "function sentimentScore() external view returns (uint8)",
  "function lastUpdateTimestamp() external view returns (uint256)",
  "function isStale() external view returns (bool)",
  "function keeper() external view returns (address)",
  "event SentimentUpdated(uint8 indexed oldScore, uint8 indexed newScore, uint8 emaScore, uint256 timestamp)",
];

// Configuration
const CONFIG = {
  // Update interval in milliseconds (default: 4 hours)
  updateInterval: parseInt(process.env.UPDATE_INTERVAL || "14400000"),
  // Minimum change in sentiment to trigger update (saves gas on small changes)
  minChangeThreshold: parseInt(process.env.MIN_CHANGE_THRESHOLD || "5"),
  // Fear & Greed Index API
  fearGreedApi: "https://api.alternative.me/fng/?limit=1",
  // CoinGecko global data (optional, for additional signal)
  coingeckoApi: "https://api.coingecko.com/api/v3/global",
};

interface FearGreedResponse {
  data: Array<{
    value: string;
    value_classification: string;
    timestamp: string;
  }>;
}

interface CoinGeckoGlobalResponse {
  data: {
    market_cap_change_percentage_24h_usd: number;
  };
}

/**
 * Fetch Fear & Greed Index from alternative.me
 * Returns a score from 0-100 (0 = extreme fear, 100 = extreme greed)
 */
async function fetchFearGreedIndex(): Promise<number> {
  try {
    const response = await fetch(CONFIG.fearGreedApi);
    const data = (await response.json()) as FearGreedResponse;

    if (data.data && data.data.length > 0) {
      const score = parseInt(data.data[0].value);
      console.log(
        `Fear & Greed Index: ${score} (${data.data[0].value_classification})`
      );
      return score;
    }
    throw new Error("Invalid response from Fear & Greed API");
  } catch (error) {
    console.error("Error fetching Fear & Greed Index:", error);
    throw error;
  }
}

/**
 * Fetch market sentiment signal from CoinGecko
 * Converts 24h market cap change to a 0-100 score
 */
async function fetchCoinGeckoSentiment(): Promise<number> {
  try {
    const response = await fetch(CONFIG.coingeckoApi);
    const data = (await response.json()) as CoinGeckoGlobalResponse;

    const change = data.data.market_cap_change_percentage_24h_usd;
    // Map -10% to +10% change to 0-100 score
    // -10% or worse = 0, +10% or better = 100
    const score = Math.min(100, Math.max(0, (change + 10) * 5));
    console.log(`CoinGecko 24h change: ${change.toFixed(2)}% -> Score: ${Math.round(score)}`);
    return Math.round(score);
  } catch (error) {
    console.error("Error fetching CoinGecko data:", error);
    // Return neutral on error
    return 50;
  }
}

/**
 * Calculate composite sentiment score from multiple sources
 * Weights: Fear & Greed = 70%, CoinGecko = 30%
 */
async function calculateCompositeSentiment(): Promise<number> {
  const fearGreed = await fetchFearGreedIndex();
  const coingecko = await fetchCoinGeckoSentiment();

  const composite = Math.round(fearGreed * 0.7 + coingecko * 0.3);
  console.log(`Composite sentiment: ${composite}`);
  return composite;
}

/**
 * Main keeper class
 */
class SentimentKeeper {
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;
  private hook: ethers.Contract;

  constructor() {
    const rpcUrl = process.env.RPC_URL;
    const privateKey = process.env.PRIVATE_KEY;
    const hookAddress = process.env.HOOK_ADDRESS;

    if (!rpcUrl || !privateKey || !hookAddress) {
      throw new Error(
        "Missing environment variables: RPC_URL, PRIVATE_KEY, HOOK_ADDRESS"
      );
    }

    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    this.wallet = new ethers.Wallet(privateKey, this.provider);
    this.hook = new ethers.Contract(hookAddress, HOOK_ABI, this.wallet);

    console.log(`Keeper initialized`);
    console.log(`  Hook: ${hookAddress}`);
    console.log(`  Keeper wallet: ${this.wallet.address}`);
  }

  /**
   * Check if we're authorized as the keeper
   */
  async verifyKeeperRole(): Promise<boolean> {
    const authorizedKeeper = await this.hook.keeper();
    const isAuthorized =
      authorizedKeeper.toLowerCase() === this.wallet.address.toLowerCase();

    if (!isAuthorized) {
      console.error(
        `Not authorized! Contract keeper: ${authorizedKeeper}, Our address: ${this.wallet.address}`
      );
    }
    return isAuthorized;
  }

  /**
   * Get current on-chain sentiment
   */
  async getCurrentSentiment(): Promise<number> {
    return await this.hook.sentimentScore();
  }

  /**
   * Check if data is stale
   */
  async isStale(): Promise<boolean> {
    return await this.hook.isStale();
  }

  /**
   * Update sentiment on-chain
   */
  async updateSentiment(score: number): Promise<void> {
    console.log(`Updating sentiment to ${score}...`);

    try {
      const tx = await this.hook.updateSentiment(score);
      console.log(`Transaction sent: ${tx.hash}`);

      const receipt = await tx.wait();
      console.log(`Transaction confirmed in block ${receipt.blockNumber}`);

      // Parse the event
      const event = receipt.logs.find(
        (log: any) => log.fragment?.name === "SentimentUpdated"
      );
      if (event) {
        console.log(`Sentiment updated: ${event.args.oldScore} -> ${event.args.emaScore} (raw: ${event.args.newScore})`);
      }
    } catch (error) {
      console.error("Error updating sentiment:", error);
      throw error;
    }
  }

  /**
   * Run one update cycle
   */
  async runOnce(): Promise<void> {
    console.log("\n=== Running sentiment update ===");
    console.log(`Timestamp: ${new Date().toISOString()}`);

    // Verify we're the keeper
    if (!(await this.verifyKeeperRole())) {
      throw new Error("Not authorized as keeper");
    }

    // Get current on-chain sentiment
    const currentSentimentBigInt = await this.getCurrentSentiment();
    const currentSentiment = Number(currentSentimentBigInt);
    const isStale = await this.isStale();
    console.log(`Current on-chain sentiment: ${currentSentiment} (stale: ${isStale})`);

    // Fetch new sentiment
    const newSentiment = await calculateCompositeSentiment();

    // Check if update is needed
    const change = Math.abs(newSentiment - currentSentiment);
    if (!isStale && change < CONFIG.minChangeThreshold) {
      console.log(
        `Change (${change}) below threshold (${CONFIG.minChangeThreshold}), skipping update`
      );
      return;
    }

    // Update on-chain
    await this.updateSentiment(newSentiment);
    console.log("=== Update complete ===\n");
  }

  /**
   * Run keeper loop
   */
  async runLoop(): Promise<void> {
    console.log(`Starting keeper loop (interval: ${CONFIG.updateInterval}ms)`);

    // Run immediately
    await this.runOnce();

    // Then run on interval
    setInterval(async () => {
      try {
        await this.runOnce();
      } catch (error) {
        console.error("Error in keeper loop:", error);
      }
    }, CONFIG.updateInterval);
  }
}

// Main entry point
async function main() {
  const args = process.argv.slice(2);
  const keeper = new SentimentKeeper();

  if (args.includes("--once")) {
    // Single run mode
    await keeper.runOnce();
  } else {
    // Continuous loop mode
    await keeper.runLoop();
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});

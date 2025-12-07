import { ethers } from "ethers";
import * as dotenv from "dotenv";

dotenv.config();

const HOOK_ABI = [
  "function updateSentiment(uint8 _rawScore) external",
  "function sentimentScore() external view returns (uint8)",
  "function isStale() external view returns (bool)",
  "function keeper() external view returns (address)",
];

/**
 * ============================================
 * FREE DATA SOURCES FOR SENTIMENT
 * ============================================
 */

interface SentimentSource {
  name: string;
  weight: number;
  fetch: () => Promise<number>;
}

// 1. Fear & Greed Index (alternative.me) - FREE, UNLIMITED
async function fetchFearGreedIndex(): Promise<number> {
  try {
    const response = await fetch("https://api.alternative.me/fng/?limit=1");
    const data = (await response.json()) as any;
    const score = parseInt(data.data[0].value);
    console.log(`  Fear & Greed Index: ${score} (${data.data[0].value_classification})`);
    return score;
  } catch (error) {
    console.error("  Fear & Greed Index: FAILED");
    return -1; // Skip this source
  }
}

// 2. CoinGecko Global Market Data - FREE (30 calls/min)
async function fetchCoinGeckoGlobal(): Promise<number> {
  try {
    const response = await fetch("https://api.coingecko.com/api/v3/global");
    const data = (await response.json()) as any;
    const change = data.data.market_cap_change_percentage_24h_usd;
    // Map -10% to +10% → 0-100
    const score = Math.min(100, Math.max(0, (change + 10) * 5));
    console.log(`  CoinGecko 24h Market Change: ${change.toFixed(2)}% → ${Math.round(score)}`);
    return Math.round(score);
  } catch (error) {
    console.error("  CoinGecko Global: FAILED");
    return -1;
  }
}

// 3. CoinGecko Trending (what's hot) - FREE
async function fetchCoinGeckoTrending(): Promise<number> {
  try {
    const response = await fetch("https://api.coingecko.com/api/v3/search/trending");
    const data = (await response.json()) as any;

    // More trending coins with positive price change = more greed
    const coins = data.coins || [];
    let positiveCount = 0;

    for (const coin of coins.slice(0, 7)) {
      const priceChange = coin.item?.data?.price_change_percentage_24h?.usd || 0;
      if (priceChange > 0) positiveCount++;
    }

    const score = Math.round((positiveCount / 7) * 100);
    console.log(`  CoinGecko Trending: ${positiveCount}/7 positive → ${score}`);
    return score;
  } catch (error) {
    console.error("  CoinGecko Trending: FAILED");
    return -1;
  }
}

// 4. CoinGecko BTC Dominance - FREE
async function fetchBTCDominance(): Promise<number> {
  try {
    const response = await fetch("https://api.coingecko.com/api/v3/global");
    const data = (await response.json()) as any;
    const btcDominance = data.data.market_cap_percentage.btc;

    // High BTC dominance (>50%) = fear (flight to safety) = lower score
    // Low BTC dominance (<40%) = greed (altcoin season) = higher score
    // Map 60% → 0, 35% → 100
    const score = Math.min(100, Math.max(0, (60 - btcDominance) * 4));
    console.log(`  BTC Dominance: ${btcDominance.toFixed(1)}% → ${Math.round(score)}`);
    return Math.round(score);
  } catch (error) {
    console.error("  BTC Dominance: FAILED");
    return -1;
  }
}

// 5. DeFi Llama TVL Change - FREE, UNLIMITED
async function fetchDefiLlamaTVL(): Promise<number> {
  try {
    const response = await fetch("https://api.llama.fi/v2/historicalChainTvl");
    const data = (await response.json()) as any[];

    if (data.length < 2) return -1;

    const latest = data[data.length - 1].tvl;
    const dayAgo = data[data.length - 2].tvl;
    const change = ((latest - dayAgo) / dayAgo) * 100;

    // Map -5% to +5% TVL change → 0-100
    const score = Math.min(100, Math.max(0, (change + 5) * 10));
    console.log(`  DeFi Llama TVL Change: ${change.toFixed(2)}% → ${Math.round(score)}`);
    return Math.round(score);
  } catch (error) {
    console.error("  DeFi Llama TVL: FAILED");
    return -1;
  }
}

// 6. CoinGecko ETH Gas (network activity) - FREE
async function fetchETHGasActivity(): Promise<number> {
  try {
    // Higher gas = more activity = more greed
    const response = await fetch(
      "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd&include_24hr_change=true"
    );
    const data = (await response.json()) as any;
    const ethChange = data.ethereum.usd_24h_change;

    // Map -10% to +10% → 0-100
    const score = Math.min(100, Math.max(0, (ethChange + 10) * 5));
    console.log(`  ETH 24h Change: ${ethChange.toFixed(2)}% → ${Math.round(score)}`);
    return Math.round(score);
  } catch (error) {
    console.error("  ETH Price: FAILED");
    return -1;
  }
}

// 7. CryptoCompare Social Stats - FREE TIER
async function fetchCryptoCompareSocial(): Promise<number> {
  try {
    const response = await fetch(
      "https://min-api.cryptocompare.com/data/social/coin/latest?coinId=1182"  // BTC
    );
    const data = (await response.json()) as any;

    // Reddit active users as sentiment proxy
    const redditActive = data.Data?.Reddit?.active_users || 0;
    // Normalize: 5000 active = neutral (50), 10000+ = greed
    const score = Math.min(100, Math.max(0, redditActive / 100));
    console.log(`  CryptoCompare Reddit Active: ${redditActive} → ${Math.round(score)}`);
    return Math.round(score);
  } catch (error) {
    console.error("  CryptoCompare Social: FAILED");
    return -1;
  }
}

// 8. Blockchain.com Market Data - FREE
async function fetchBlockchainStats(): Promise<number> {
  try {
    const response = await fetch("https://api.blockchain.info/stats");
    const data = (await response.json()) as any;

    // Transaction count as activity indicator
    const txCount = data.n_tx || 0;
    // Normalize around 300k tx/day = neutral
    const score = Math.min(100, Math.max(0, (txCount / 300000) * 50));
    console.log(`  Blockchain.com TX Count: ${txCount} → ${Math.round(score)}`);
    return Math.round(score);
  } catch (error) {
    console.error("  Blockchain.com: FAILED");
    return -1;
  }
}

/**
 * ============================================
 * AGGREGATE ALL SOURCES
 * ============================================
 */

const SENTIMENT_SOURCES: SentimentSource[] = [
  { name: "Fear & Greed Index", weight: 30, fetch: fetchFearGreedIndex },
  { name: "CoinGecko Global", weight: 20, fetch: fetchCoinGeckoGlobal },
  { name: "CoinGecko Trending", weight: 10, fetch: fetchCoinGeckoTrending },
  { name: "BTC Dominance", weight: 10, fetch: fetchBTCDominance },
  { name: "DeFi Llama TVL", weight: 10, fetch: fetchDefiLlamaTVL },
  { name: "ETH Price", weight: 10, fetch: fetchETHGasActivity },
  { name: "CryptoCompare Social", weight: 5, fetch: fetchCryptoCompareSocial },
  { name: "Blockchain.com Stats", weight: 5, fetch: fetchBlockchainStats },
];

async function calculateMultiSourceSentiment(): Promise<number> {
  console.log("\nFetching from all free data sources...\n");

  const results: { source: SentimentSource; score: number }[] = [];

  // Fetch all sources (with small delays to avoid rate limits)
  for (const source of SENTIMENT_SOURCES) {
    const score = await source.fetch();
    if (score >= 0) {
      results.push({ source, score });
    }
    await new Promise(resolve => setTimeout(resolve, 200)); // 200ms delay
  }

  if (results.length === 0) {
    console.log("\nAll sources failed! Using neutral sentiment.");
    return 50;
  }

  // Calculate weighted average (only from successful fetches)
  const totalWeight = results.reduce((sum, r) => sum + r.source.weight, 0);
  const weightedSum = results.reduce((sum, r) => sum + r.score * r.source.weight, 0);
  const composite = Math.round(weightedSum / totalWeight);

  console.log("\n========================================");
  console.log(`Sources used: ${results.length}/${SENTIMENT_SOURCES.length}`);
  console.log(`Composite Sentiment: ${composite}`);
  console.log("========================================\n");

  return composite;
}

/**
 * ============================================
 * KEEPER CLASS
 * ============================================
 */

class MultiSourceKeeper {
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;
  private hook: ethers.Contract;

  constructor() {
    const rpcUrl = process.env.RPC_URL;
    const privateKey = process.env.PRIVATE_KEY;
    const hookAddress = process.env.HOOK_ADDRESS;

    if (!rpcUrl || !privateKey || !hookAddress) {
      throw new Error("Missing: RPC_URL, PRIVATE_KEY, HOOK_ADDRESS");
    }

    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    this.wallet = new ethers.Wallet(privateKey, this.provider);
    this.hook = new ethers.Contract(hookAddress, HOOK_ABI, this.wallet);

    console.log("Multi-Source Sentiment Keeper");
    console.log(`  Hook: ${hookAddress}`);
    console.log(`  Wallet: ${this.wallet.address}`);
  }

  async runOnce(): Promise<void> {
    console.log("\n=== MULTI-SOURCE SENTIMENT UPDATE ===");
    console.log(`Time: ${new Date().toISOString()}`);

    // Verify keeper role
    const authorizedKeeper = await this.hook.keeper();
    if (authorizedKeeper.toLowerCase() !== this.wallet.address.toLowerCase()) {
      throw new Error(`Not authorized! Keeper: ${authorizedKeeper}`);
    }

    // Get current state
    const currentSentiment = Number(await this.hook.sentimentScore());
    const isStale = await this.hook.isStale();
    console.log(`\nCurrent on-chain: ${currentSentiment} (stale: ${isStale})`);

    // Fetch multi-source sentiment
    const newSentiment = await calculateMultiSourceSentiment();

    // Update if changed significantly or stale
    const change = Math.abs(newSentiment - currentSentiment);
    const threshold = parseInt(process.env.MIN_CHANGE_THRESHOLD || "5");

    if (!isStale && change < threshold) {
      console.log(`Change (${change}) < threshold (${threshold}), skipping.`);
      return;
    }

    // Send transaction
    console.log(`Updating sentiment: ${currentSentiment} → ${newSentiment}`);
    const tx = await this.hook.updateSentiment(newSentiment);
    console.log(`TX: ${tx.hash}`);

    const receipt = await tx.wait();
    console.log(`Confirmed in block ${receipt.blockNumber}`);
  }
}

// Main
async function main() {
  const keeper = new MultiSourceKeeper();

  if (process.argv.includes("--once")) {
    await keeper.runOnce();
  } else {
    // Loop mode
    const interval = parseInt(process.env.UPDATE_INTERVAL || "14400000");
    console.log(`Running every ${interval / 1000 / 60} minutes`);

    await keeper.runOnce();
    setInterval(() => keeper.runOnce().catch(console.error), interval);
  }
}

main().catch((error) => {
  console.error("Fatal:", error);
  process.exit(1);
});

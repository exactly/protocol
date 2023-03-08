import { ethers } from "hardhat";
import { MockPriceFeed } from "../types";

const { SCRIPT_MARKET } = process.env;
if (!SCRIPT_MARKET) throw new Error("missing SCRIPT_MARKET");

const id = {
  WETH: "ethereum",
  DAI: "dai",
  USDC: "usd-coin",
  WBTC: "wrapped-bitcoin",
  wstETH: "wrapped-steth",
  OP: "optimism",
}[SCRIPT_MARKET];
if (!id) throw new Error(`unknown market: ${SCRIPT_MARKET}`);

void Promise.all([
  fetch(`https://api.coingecko.com/api/v3/simple/price?ids=${id}&vs_currencies=usd`),
  ethers.getContract<MockPriceFeed>(`PriceFeed${SCRIPT_MARKET}`),
  ethers.getSigners(),
]).then(async ([price, priceFeed, [signer]]) => {
  const { [id]: assetPrice } = (await price.json()) as Record<string, Record<string, number>>;
  console.log(SCRIPT_MARKET, assetPrice.usd);

  const tx = await priceFeed.connect(signer).setPrice(BigInt(Math.round(assetPrice.usd * 1e8)));
  console.log(tx.hash);
});

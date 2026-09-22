import { ethers } from "hardhat";
import { address as auditorAddress } from "../deployments/optimism/Auditor.json";
import { address as multicallAddress, abi as multicallABI } from "../deployments/optimism/Multicall3.json";

const tolerance = 10_000n;
const interval = 4 * 7 * 86_400;
const firstMaturity = 1_674_086_400;
const market = new ethers.Interface([
  "function fixedOps() view returns (uint256 deposits, uint256 borrows)",
  "function fixedPools(uint256) view returns (uint256 borrowed, uint256 supplied, uint256 unassigned, uint256 accrual)",
  "function maxFuturePools() view returns (uint8)",
  "function symbol() view returns (string)",
]);

void (async () => {
  const multicall = new ethers.Contract(multicallAddress, multicallABI, ethers.provider);
  const auditor = new ethers.Contract(
    auditorAddress,
    ["function allMarkets() view returns (address[])"],
    ethers.provider,
  );
  const aggregate = async (calls: { target: string; callData: string }[]) =>
    ((await multicall.aggregate.staticCall(calls)) as [bigint, string[]])[1];
  const decode = <T>(fn: string, data: string) => market.decodeFunctionResult(fn, data) as unknown as T;
  const now = Math.floor(Date.now() / 1_000);

  let backfilled = true;
  for (const target of (await auditor.allMarkets()) as string[]) {
    const head = await aggregate([
      { target, callData: market.encodeFunctionData("symbol") },
      { target, callData: market.encodeFunctionData("maxFuturePools") },
    ]);
    const [symbol] = decode<[string]>("symbol", head[0]);
    const [pools] = decode<[bigint]>("maxFuturePools", head[1]);
    const maturities: number[] = [];
    const last = now - (now % interval) + interval * Number(pools);
    for (let maturity = firstMaturity; maturity <= last; maturity += interval) maturities.push(maturity);

    const data = await aggregate([
      { target, callData: market.encodeFunctionData("fixedOps") },
      ...maturities.map((maturity) => ({ target, callData: market.encodeFunctionData("fixedPools", [maturity]) })),
    ]);
    const [deposits, borrows] = decode<[bigint, bigint]>("fixedOps", data[0]);
    const gap = data.slice(1).reduce(
      (sum, pool) => {
        const [borrowed, supplied] = decode<[bigint, bigint]>("fixedPools", pool);
        return { depositsGap: sum.depositsGap + supplied, borrowsGap: sum.borrowsGap + borrowed };
      },
      { depositsGap: -deposits, borrowsGap: -borrows },
    );
    if (gap.depositsGap > tolerance || gap.borrowsGap > tolerance) backfilled = false;
    console.log(symbol, gap);
  }

  if (!backfilled) throw new Error("fixed totals not backfilled");
  console.log("fixed totals backfilled");
})().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});

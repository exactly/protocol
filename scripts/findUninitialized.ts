import { ethers } from "hardhat";
import { readFile, writeFile } from "fs/promises";
import { address as multicallAddress, abi as multicallABI } from "../deployments/optimism/Multicall3.json";

const markets = ["MarketUSDC", "MarketUSDC.e", "MarketWETH", "MarketwstETH", "MarketOP", "MarketWBTC"];
const batchSize = 400;
const market = new ethers.Interface([
  "function accounts(address) view returns (uint256 fixedDeposits, uint256 fixedBorrows, uint256 floatingBorrowShares)",
  "function isInitialized(address) view returns (bool)",
]);

void (async () => {
  const multicall = new ethers.Contract(multicallAddress, multicallABI, ethers.provider);
  const accounts = JSON.parse(await readFile("scripts/accounts.json", "utf8")) as string[];
  const block = await ethers.provider.getBlockNumber();
  const targets: Record<string, string[]> = {};

  for (const name of markets) {
    const { address: target } = JSON.parse(await readFile(`deployments/optimism/${name}.json`, "utf8")) as {
      address: string;
    };
    const pending: string[] = [];
    for (let i = 0; i < accounts.length; i += batchSize) {
      const batch = accounts.slice(i, i + batchSize);
      const [, data] = (await multicall.aggregate.staticCall(
        batch.flatMap((account) => [
          { target, callData: market.encodeFunctionData("accounts", [account]) },
          { target, callData: market.encodeFunctionData("isInitialized", [account]) },
        ]),
        { blockTag: block },
      )) as [bigint, string[]];
      batch.forEach((account, j) => {
        const [fixedDeposits, fixedBorrows] = market.decodeFunctionResult("accounts", data[2 * j]) as unknown as [
          bigint,
          bigint,
        ];
        const [initialized] = market.decodeFunctionResult("isInitialized", data[2 * j + 1]) as unknown as [boolean];
        if (!initialized && (fixedDeposits !== 0n || fixedBorrows !== 0n)) pending.push(account);
      });
    }
    targets[target.toLowerCase()] = pending;
    console.log(name, pending.length);
  }

  await writeFile("scripts/uninitialized.json", JSON.stringify({ block, targets }, null, 2));
})();

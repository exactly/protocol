import { ethers } from "hardhat";
import { readFile } from "fs/promises";
import { address as multicallAddress, abi as multicallABI } from "../deployments/optimism/Multicall3.json";

const offset = Number(process.env.OFFSET ?? 0);
const limit = Number(process.env.LIMIT ?? Infinity);
const batchSize = 100;

void (async () => {
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("no signer configured, set MNEMONIC or PRIVATE_KEY");

  const multicall = new ethers.Contract(multicallAddress, multicallABI, ethers.provider);
  const market = new ethers.Interface([
    "function initConsolidated(address)",
    "function isInitialized(address) view returns (bool)",
  ]);
  const { targets } = JSON.parse(await readFile("scripts/uninitialized.json", "utf8")) as {
    targets: Record<string, string[]>;
  };
  const pending = Object.entries(targets)
    .flatMap(([target, accounts]) => accounts.map((account) => ({ target, account })))
    .slice(offset, offset + limit);

  let sent = 0;
  let skipped = 0;

  for (let i = 0; i < pending.length; i += batchSize) {
    const slice = pending.slice(i, i + batchSize);
    const [, states] = (await multicall.aggregate.staticCall(
      slice.map(({ target, account }) => ({ target, callData: market.encodeFunctionData("isInitialized", [account]) })),
    )) as [bigint, string[]];

    const batch = slice
      .filter((_, j) => !(market.decodeFunctionResult("isInitialized", states[j])[0] as boolean))
      .map(({ target, account }) => ({ target, callData: market.encodeFunctionData("initConsolidated", [account]) }));

    const done = offset + i + slice.length;
    const remaining = pending.length - i - slice.length;
    skipped += slice.length - batch.length;

    if (!batch.length) {
      console.log(
        `${done}/${offset + pending.length} skipped ${slice.length} already initialized, ${remaining} remaining`,
      );
      continue;
    }

    const sender = new ethers.Contract(multicallAddress, multicallABI, signer);
    const tx = (await sender.aggregate(batch)) as { hash: string; wait: () => Promise<unknown> };
    await tx.wait();
    sent += batch.length;
    console.log(
      `${done}/${offset + pending.length} sent ${batch.length}, skipped ${slice.length - batch.length} already initialized, ${remaining} remaining ${tx.hash}`,
    );
  }

  console.log(`finished: initialized ${sent} accounts, skipped ${skipped} already initialized`);
})();

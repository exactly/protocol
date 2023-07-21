import { writeFile } from "fs/promises";
import { address as op } from "../deployments/optimism/OP.json";

const block = 107_054_000;
const subgraph = "https://api.thegraph.com/subgraphs/name/exactly/optimism";
const jsonPOST = { method: "POST", headers: { "Content-Type": "application/json" } };

const allAccounts = async () => {
  let last: string | undefined = "";
  const set = new Set<string>();
  do {
    const { accounts } = (
      await (
        await fetch(subgraph, {
          ...jsonPOST,
          body: JSON.stringify({
            query: `{
              accounts(
                first: 1000
                block: { number: ${block} }
                where: { address_gt: "${last}" }
                orderBy: address
                orderDirection: asc
              ) { address }
            }`,
          }),
        })
      ).json()
    ).data as { accounts: { address: string }[] };
    accounts.forEach(({ address }: { address: string }) => set.add(address));
    last = accounts.length ? [...set][set.size - 1] : undefined;
  } while (last);
  return [...set];
};

const opClaimed = async () => {
  let last: string | undefined = "";
  const claimed: [string, string][] = [];
  do {
    const { rewardsClaims } = (
      await (
        await fetch(subgraph, {
          ...jsonPOST,
          body: JSON.stringify({
            query: `{
              rewardsClaims(
                first: 1000
                block: { number: ${block} }
                where: { reward: "${op}", account_gt: "${last}" }
                orderBy: account
                orderDirection: asc
              ) { account, amount }
            }`,
          }),
        })
      ).json()
    ).data as { rewardsClaims: { account: string; amount: string }[] };
    last = rewardsClaims.length ? rewardsClaims[rewardsClaims.length - 1]?.account : undefined;
    claimed.push(...rewardsClaims.map(({ account, amount }) => [account, amount] satisfies [string, string]));
  } while (last);
  return Object.fromEntries(claimed);
};

void (async () => {
  const [accounts, claimed] = await Promise.all([allAccounts(), opClaimed()]);
  await Promise.all([
    writeFile("scripts/accounts.json", JSON.stringify(accounts, null, 2)),
    writeFile(
      "scripts/claimed.json",
      JSON.stringify(Object.fromEntries(accounts.map((account) => [account, claimed[account] ?? "0"])), null, 2),
    ),
  ]);
})();

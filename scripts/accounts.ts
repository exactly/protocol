import { writeFile } from "fs/promises";
import allAccounts from "./utils/allAccounts";

const block = 136_156_200;
const subgraph =
  "https://gateway-arbitrum.network.thegraph.com/api/3bd03f49a36caaa5ed4efc5a27c5425d/subgraphs/id/9jpa2F3ZuirB11m3GL36wcNoNGETd3Z2zf7Cre5iwyeC";

void (async () => {
  const accounts = await allAccounts(subgraph, block);
  await writeFile("scripts/accounts.json", JSON.stringify(accounts, null, 2));
})();

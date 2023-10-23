import { argv } from "process";
import { readFileSync } from "fs";

const file = argv[2];
if (!file) throw new Error("missing file argument");

const { chain, transactions } = JSON.parse(readFileSync(file).toString()) as {
  chain: number;
  transactions: { transaction: { from: string; to: string; data: string; value: string } }[];
};
console.log(
  JSON.stringify(
    {
      chainId: String(chain),
      meta: {
        createdFromSafeAddress: transactions.reduce((address, { transaction: { from } }) => {
          if (address && address !== from) throw new Error("multiple safe addresses");
          return from;
        }, ""),
      },
      transactions: transactions.map(({ transaction: { to, data, value } }) => ({ to, data, value })),
    },
    null,
    2,
  ),
);

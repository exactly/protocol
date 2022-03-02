import { BigNumber } from "ethers";

export default (n = 12, interval = 86_400 * 7) => {
  const now = Math.floor(Date.now() / 1_000);
  return [...new Array(n)].map((_, i) => BigNumber.from(now - (now % interval) + interval * (i + 1)));
};

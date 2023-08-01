import type { BigNumber } from "ethers";
import { INTERVAL } from "./futurePools";

export default (encodedMaturities: BigNumber) => {
  const maturities: number[] = [];
  const baseMaturity = encodedMaturities.mod(1n << 32n).toNumber();
  const packedMaturities = encodedMaturities.shr(32);
  for (let i = 0; !packedMaturities.shr(i).eq(0); i++) {
    if (packedMaturities.and(1n << BigInt(i)).eq(1)) maturities.push(baseMaturity + i * INTERVAL);
  }
  return maturities;
};

import { INTERVAL } from "./futurePools";

export default (encodedMaturities: bigint) => {
  const maturities: number[] = [];
  const baseMaturity = Number(encodedMaturities % (1n << 32n));
  const packedMaturities = encodedMaturities >> 32n;
  for (let i = 0n; packedMaturities >> i !== 0n; i++) {
    if ((packedMaturities | (1n << i)) === 1n) maturities.push(baseMaturity + Number(i) * INTERVAL);
  }
  return maturities;
};

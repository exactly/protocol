import { ethers } from "hardhat";

export const INTERVAL = 86_400 * 7 * 4;

export default async (n = 3) => {
  const { timestamp } = (await ethers.provider.getBlock("latest"))!;
  return [...new Array(n)].map((_, i) => timestamp - (timestamp % INTERVAL) + INTERVAL * (i + 1));
};

import { ethers, network } from "hardhat";
import { Market } from "../../../types";
import DEAD_ADDRESS from "../../../deploy/.utils/DEAD_ADDRESS";

export default async (market: Market) => {
  await network.provider.request({ method: "hardhat_impersonateAccount", params: [DEAD_ADDRESS] });
  await network.provider.send("hardhat_setBalance", [DEAD_ADDRESS, "0x100000000"]);
  const deadSigner = await ethers.getSigner(DEAD_ADDRESS);
  await market.connect(deadSigner).withdraw(await market.maxWithdraw(DEAD_ADDRESS), DEAD_ADDRESS, DEAD_ADDRESS);
};

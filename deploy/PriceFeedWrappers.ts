import { BigNumber } from "ethers";
import { Interface } from "@ethersproject/abi";
import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({ network, deployments: { deploy, get }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();

  for (const [symbol, { wrap }] of Object.entries(network.config.markets)) {
    if (!wrap) continue;

    const { address, abi } = await get(wrap.wrapper);
    await tenderlify(
      "PriceFeedWrapper",
      await deploy(`PriceFeed${symbol}`, {
        contract: "PriceFeedWrapper",
        args: [
          (await get(`PriceFeedMain${symbol}`)).address,
          address,
          new Interface(abi).getSighash(wrap.fn),
          BigNumber.from(wrap.baseUnit),
        ],
        from: deployer,
        log: true,
      }),
    );
  }
};

func.tags = ["PriceFeedWrappers"];
func.dependencies = ["Assets"];

export default func;

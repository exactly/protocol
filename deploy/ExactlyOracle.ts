import type { DeployFunction } from "hardhat-deploy/types";

export const USD_ADDRESS = "0x0000000000000000000000000000000000000348";
export const ETH_ADDRESS = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
export const BTC_ADDRESS = "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("ExactlyOracle", {
    args: [(await get("FeedRegistry")).address, 86_400],
    from: deployer,
    log: true,
  });
};

func.tags = ["ExactlyOracle"];
func.dependencies = ["FeedRegistry", "Tokens", "TimelockController"];

export default func;

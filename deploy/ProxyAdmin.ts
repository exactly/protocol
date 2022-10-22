import type { DeployFunction } from "hardhat-deploy/types";
import type { ProxyAdmin } from "../types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({
  ethers: { getContract, getSigner },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [{ address: timelockAddress }, { deployer }] = await Promise.all([
    get("TimelockController"),
    getNamedAccounts(),
  ]);
  await tenderlify(
    "ProxyAdmin",
    await deploy("ProxyAdmin", { skipIfAlreadyDeployed: true, from: deployer, log: true }),
  );

  const proxyAdmin = await getContract<ProxyAdmin>("ProxyAdmin", await getSigner(deployer));
  if ((await proxyAdmin.owner()).toLowerCase() !== timelockAddress.toLowerCase()) {
    await (await proxyAdmin.transferOwnership(timelockAddress)).wait();
  }
};

func.tags = ["ProxyAdmin"];
func.dependencies = ["TimelockController"];

export default func;

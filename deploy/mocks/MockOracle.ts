import { env } from "process";
import type { DeployFunction } from "hardhat-deploy/types";
import type { MockOracle } from "../../types";

export const MOCK_ORACLE = !!JSON.parse(env.MOCK_ORACLE ?? "false");

const func: DeployFunction = async ({
  network: { config },
  ethers: {
    utils: { parseUnits },
    getContract,
    getSigner,
  },
  deployments: { deploy, get, log },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  await deploy("MockOracle", { skipIfAlreadyDeployed: true, from: deployer, log: true });
  const oracle = await getContract<MockOracle>("MockOracle", await getSigner(deployer));
  for (const symbol of config.tokens) {
    const priceString = env[`${symbol}_PRICE`];
    if (priceString) {
      const price = parseUnits(priceString);
      const { address } = await get(`FixedLender${symbol}`);
      if (!price.eq(await oracle.getAssetPrice(address))) {
        log("setting price", symbol, priceString);
        await (await oracle.setPrice(address, price)).wait();
      }
    }
  }
};

func.tags = ["MockOracle"];
func.skip = async () => !MOCK_ORACLE;

export default func;

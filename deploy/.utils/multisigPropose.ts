import Safe from "@gnosis.pm/safe-core-sdk";
import EthersAdapter from "@gnosis.pm/safe-ethers-lib";
import SafeServiceClient from "@gnosis.pm/safe-service-client";
import type { Contract } from "ethers";
import type { HardhatRuntimeEnvironment } from "hardhat/types";

export default async (
  { deployments: { log }, ethers, network, getNamedAccounts }: HardhatRuntimeEnvironment,
  account: string,
  contract: Contract,
  functionName: string,
  args?: readonly unknown[],
) => {
  const { [account]: senderAddress, multisig: safeAddress } = await getNamedAccounts();
  const ethAdapter = new EthersAdapter({ ethers, signer: await ethers.getSigner(senderAddress) });
  const safeService = new SafeServiceClient({ txServiceUrl: network.config.gnosisSafeTxService, ethAdapter });
  const safeSdk = await Safe.create({ ethAdapter, safeAddress });
  const calldata = contract.interface.encodeFunctionData(functionName, args);
  if (
    !(await safeService.getPendingTransactions(safeAddress)).results.find(
      ({ to, data }) => to === contract.address && data === calldata,
    )
  ) {
    log("multisig: proposing", contract.address, functionName, args);
    const safeTransaction = await safeSdk.createTransaction({ to: contract.address, value: "0", data: calldata });
    await safeSdk.signTransaction(safeTransaction);
    await safeService.proposeTransaction({
      safeAddress,
      safeTransaction,
      safeTxHash: await safeSdk.getTransactionHash(safeTransaction),
      senderAddress,
    });
  }
};

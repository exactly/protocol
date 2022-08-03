import Safe from "@gnosis.pm/safe-core-sdk";
import EthersAdapter from "@gnosis.pm/safe-ethers-lib";
import SafeServiceClient from "@gnosis.pm/safe-service-client";
import type { Contract } from "ethers";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import format from "./format";

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
    log("multisig: proposing", `${await format(contract.address)}.${functionName}`, await format(args));
    const safeTransaction = await safeSdk.createTransaction({ to: contract.address, value: "0", data: calldata });
    const safeTxHash = await safeSdk.getTransactionHash(safeTransaction);
    const senderSignature = await safeSdk.signTransactionHash(safeTxHash);
    await safeService.proposeTransaction({
      safeAddress,
      safeTxHash,
      safeTransactionData: safeTransaction.data,
      senderSignature: senderSignature.data,
      senderAddress,
    });
  }
};

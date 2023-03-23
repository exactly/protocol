import Safe from "@safe-global/safe-core-sdk";
import EthersAdapter from "@safe-global/safe-ethers-lib";
import SafeServiceClient from "@safe-global/safe-service-client";
import { ethers, network, getNamedAccounts } from "hardhat";
import { getAddress } from "ethers/lib/utils";
import type { Contract } from "ethers";
import format from "./format";

export default async (account: string, contract: Contract, functionName: string, args: readonly unknown[] = []) => {
  const { safeTxService: txServiceUrl } = network.config;
  if (!txServiceUrl) throw new Error("missing safeTxService");

  const { [account]: senderAddress, multisig: safeAddress } = await getNamedAccounts();
  const ethAdapter = new EthersAdapter({ ethers, signerOrProvider: await ethers.getSigner(senderAddress) });
  const safeService = new SafeServiceClient({ txServiceUrl, ethAdapter });
  const calldata = contract.interface.encodeFunctionData(functionName, args);
  if (
    !(await safeService.getPendingTransactions(safeAddress)).results.find(
      ({ to, data }) => to === contract.address && data === calldata,
    )
  ) {
    // eslint-disable-next-line no-console
    console.log("multisig: proposing", `${await format(contract.address)}.${functionName}`, await format(args));
    const safeSdk = await Safe.create({ ethAdapter, safeAddress });
    if (!(await safeSdk.isOwner(senderAddress))) {
      // eslint-disable-next-line no-console
      console.log("multisig: manual proposal", { to: contract.address, data: calldata, value: "0" });
      return;
    }
    const safeTransaction = await safeSdk.createTransaction({
      safeTransactionData: {
        to: getAddress(contract.address),
        data: calldata,
        value: "0",
        nonce: await safeService.getNextNonce(safeAddress),
      },
    });
    const safeTxHash = await safeSdk.getTransactionHash(safeTransaction);
    const senderSignature = await safeSdk.signTransactionHash(safeTxHash);
    await safeService.proposeTransaction({
      safeTxHash,
      safeAddress,
      senderAddress,
      senderSignature: senderSignature.data,
      safeTransactionData: safeTransaction.data,
      origin: "deploy",
    });
  }
};

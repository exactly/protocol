import { ethers, network, getNamedAccounts } from "hardhat";
import SafeApiKit from "@safe-global/api-kit";
import Safe, { EthersAdapter } from "@safe-global/protocol-kit";
import type { BaseContract } from "ethers";
import format from "./format";

export default async (account: string, contract: BaseContract, functionName: string, args: readonly unknown[] = []) => {
  const { [account]: senderAddress, multisig: safeAddress } = await getNamedAccounts();
  const ethAdapter = new EthersAdapter({ ethers, signerOrProvider: await ethers.getSigner(senderAddress) });
  const safeApiKit = new SafeApiKit({
    chainId: BigInt(network.config.chainId ?? (await ethers.provider.getNetwork()).chainId),
  });
  const to = await contract.getAddress();
  const data = contract.interface.encodeFunctionData(functionName, args);
  if (!(await safeApiKit.getPendingTransactions(safeAddress)).results.find((tx) => tx.to === to && tx.data === data)) {
    // eslint-disable-next-line no-console
    console.log("multisig: proposing", `${await format(to)}.${functionName}`, await format(args));
    const safeSdk = await Safe.create({ ethAdapter, safeAddress });
    if (!(await safeSdk.isOwner(senderAddress))) {
      // eslint-disable-next-line no-console
      console.log("multisig: manual proposal", { to, data, value: "0" });
      return;
    }
    const safeTransaction = await safeSdk.createTransaction({
      transactions: [{ to, data, value: "0" }],
      options: { nonce: await safeApiKit.getNextNonce(safeAddress) },
    });
    const safeTxHash = await safeSdk.getTransactionHash(safeTransaction);
    const senderSignature = await safeSdk.signHash(safeTxHash);
    await safeApiKit.proposeTransaction({
      safeTxHash,
      safeAddress,
      senderAddress,
      senderSignature: senderSignature.data,
      safeTransactionData: safeTransaction.data,
      origin: "deploy",
    });
  }
};

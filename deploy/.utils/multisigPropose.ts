import { ethers, network, getNamedAccounts } from "hardhat";
import SafeApiKit from "@safe-global/api-kit";
import Safe from "@safe-global/protocol-kit";
import type { BaseContract } from "ethers";
import format from "./format";

export default async (
  account: string,
  contract: BaseContract,
  functionName: string,
  args: readonly unknown[] = [],
  safe = "multisig",
) => {
  const { [account]: senderAddress, [safe]: safeAddress } = await getNamedAccounts();
  const safeApiKit = new SafeApiKit({
    chainId: BigInt(network.config.chainId ?? (await ethers.provider.getNetwork()).chainId),
  });
  const to = await contract.getAddress();
  const data = contract.interface.encodeFunctionData(functionName, args);
  try {
    if (
      !(await safeApiKit.getPendingTransactions(safeAddress)).results.find((tx) => tx.to === to && tx.data === data)
    ) {
      // eslint-disable-next-line no-console
      console.log(`${safe}: proposing`, `${await format(to)}.${functionName}`, await format(args));
      const safeSdk = await Safe.init({ safeAddress, signer: senderAddress, provider: network.provider });
      if (!(await safeSdk.isOwner(senderAddress))) return printManual(safe, to, data);
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
  } catch (error) {
    if (senderAddress !== safeAddress) {
      // eslint-disable-next-line no-console
      console.log(`${safe}: error`, error instanceof Error ? error.message : error);
      return printManual(safe, to, data);
    }
    throw error;
  }
};

function printManual(safe: string, to: string, data: string) {
  // eslint-disable-next-line no-console
  console.log(`${safe}: manual proposal`, { to, data, value: "0" });
}

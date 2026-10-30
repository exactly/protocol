import { env } from "process";
import { ethers, network, getNamedAccounts } from "hardhat";
import { TypedDataEncoder, ZeroAddress, type BaseContract } from "ethers";
import format from "./format";

const services: Record<string, string> = { 1: "eth", 10: "oeth", 8453: "base", 84532: "basesep" };
const types = {
  SafeTx: [
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "data", type: "bytes" },
    { name: "operation", type: "uint8" },
    { name: "safeTxGas", type: "uint256" },
    { name: "baseGas", type: "uint256" },
    { name: "gasPrice", type: "uint256" },
    { name: "gasToken", type: "address" },
    { name: "refundReceiver", type: "address" },
    { name: "nonce", type: "uint256" },
  ],
};

export default async (
  account: string,
  contract: BaseContract,
  functionName: string,
  args: readonly unknown[] = [],
  safe = "multisig",
) => {
  const { [account]: sender, [safe]: safeAddress } = await getNamedAccounts();
  const chainId = network.config.chainId ?? (await ethers.provider.getNetwork()).chainId;
  const service = services[String(chainId)];
  if (!service) throw new Error(`no safe transaction service for chain ${chainId}`);
  const api = async <T>(path: string, body?: object) => {
    const response = await fetch(`https://api.safe.global/tx-service/${service}/api/v1/safes/${safeAddress}/${path}`, {
      method: body ? "POST" : "GET",
      headers: {
        "Content-Type": "application/json",
        ...(env.SAFE_API_KEY ? { Authorization: `Bearer ${env.SAFE_API_KEY}` } : {}),
      },
      body: body && JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(text || response.statusText);
    return (text && JSON.parse(text)) as T;
  };
  const to = await contract.getAddress();
  const data = contract.interface.encodeFunctionData(functionName, args);
  try {
    const { nonce } = await api<{ nonce: string }>("");
    const { results } = await api<{ results: { to: string; data: string | null; nonce: number }[] }>(
      `multisig-transactions/?executed=false&nonce__gte=${nonce}`,
    );
    if (results.some((tx) => tx.to === to && tx.data === data)) return;

    // eslint-disable-next-line no-console
    console.log(`${safe}: proposing`, `${await format(to)}.${functionName}`, await format(args));
    const domain = { chainId, verifyingContract: safeAddress };
    const safeTx = {
      to,
      value: 0,
      data,
      operation: 0,
      safeTxGas: 0,
      baseGas: 0,
      gasPrice: 0,
      gasToken: ZeroAddress,
      refundReceiver: ZeroAddress,
      nonce: Math.max(Number(nonce), ...results.map((tx) => Number(tx.nonce) + 1)),
    };
    await api("multisig-transactions/", {
      ...safeTx,
      contractTransactionHash: TypedDataEncoder.hash(domain, types, safeTx),
      sender,
      signature: await (await ethers.getSigner(sender)).signTypedData(domain, types, safeTx),
      origin: "deploy",
    });
  } catch (error) {
    if (sender !== safeAddress) {
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

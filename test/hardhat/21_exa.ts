import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { EXA } from "../../types";

const { ZeroHash, getNamedSigner, getContract } = ethers;
const { fixture, get } = deployments;

describe("EXA", function () {
  let exa: EXA;
  let deployer: SignerWithAddress;

  before(async () => {
    deployer = await getNamedSigner("deployer");
  });

  beforeEach(async () => {
    await fixture("EXA");

    exa = await getContract<EXA>("EXA", deployer);
  });

  it("THEN deploy script grants DEFAULT_ADMIN_ROLE to timelock only", async () => {
    const { address: timelock } = await get("TimelockController");
    expect(await exa.hasRole(ZeroHash, timelock)).to.equal(true);
    expect(await exa.hasRole(ZeroHash, deployer.address)).to.equal(false);
  });
});

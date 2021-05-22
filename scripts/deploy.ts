import { ethers } from "hardhat";

async function main() {
  // We get the contract to deploy
  const Lender = await ethers.getContractFactory("Lender");
  const lender = await Lender.deploy();

  console.log("Lender deployed to:", lender.address);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });

import { ethers } from "hardhat";

async function main() {
  // We get the contract to deploy
  const Exafin = await ethers.getContractFactory("Exafin");
  const exafin = await Exafin.deploy();

  console.log("Exafin deployed to:", exafin.address);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });

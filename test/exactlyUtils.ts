import { ethers } from "hardhat"
import { Contract, BigNumber, ContractTransaction, ContractReceipt } from "ethers"
import { assert } from "console";

export interface BorrowEventInterface {
    to: string;
    amount: BigNumber;
    commission: BigNumber;
    maturityDate: BigNumber;
}

export interface SuppliedEventInterface {
    from: string;
    amount: BigNumber;
    commission: BigNumber;
    maturityDate: BigNumber;
}

export function parseBorrowEvent(tx: ContractTransaction) {
    return new Promise<BorrowEventInterface>(async (resolve, reject) => {
        let receipt: ContractReceipt = await tx.wait();
        let args = receipt.events?.filter((x) => { return x.event == "Borrowed" })[0]["args"]

        if (args != undefined) {
            resolve({
                to: args.to.toString(),
                amount: BigNumber.from(args.amount),
                commission: BigNumber.from(args.commission),
                maturityDate: BigNumber.from(args.maturityDate)
            })
        } else {
            reject(new Error('Event not found'))
        }
    })
}

export function parseSupplyEvent(tx: ContractTransaction) {
    return new Promise<SuppliedEventInterface>(async (resolve, reject) => {
        let receipt: ContractReceipt = await tx.wait();
        let args = receipt.events?.filter((x) => { return x.event == "Supplied" })[0]["args"]

        if (args != undefined) {
            resolve({
                from: args.from.toString(),
                amount: BigNumber.from(args.amount),
                commission: BigNumber.from(args.commission),
                maturityDate: BigNumber.from(args.maturityDate)
            })
        } else {
            reject(new Error('Event not found'))
        }
    })
}

export class ExactlyEnv {
    oracle: Contract
    exaFront: Contract
    exafinContracts: Map<string, Contract>
    underlyingContracts: Map<string, Contract>

    constructor(
        _oracle: Contract,
        _exaFront: Contract,
        _exafinContracts: Map<string, Contract>,
        _underlyingContracts: Map<string, Contract>
    ) {
        this.oracle = _oracle
        this.exaFront = _exaFront
        this.exafinContracts = _exafinContracts
        this.underlyingContracts = _underlyingContracts
    }

    public getExafin(key: string): Contract {
        return this.exafinContracts.get(key)!
    }

    public getUnderlying(key: string): Contract {
        return this.underlyingContracts.get(key)!
    }

    static async create(
        tokensUSDPrice: Map<string, BigNumber>,
        tokensCollateralRate: Map<string, BigNumber>
    ): Promise<ExactlyEnv> {

        let exafinContracts = new Map<string, Contract>();
        let underlyingContracts = new Map<string, Contract>();

        const SomeOracle = await ethers.getContractFactory("SomeOracle")
        let oracle = await SomeOracle.deploy()
        await oracle.deployed()
        
        const ExaFront = await ethers.getContractFactory("ExaFront")
        let exaFront = await ExaFront.deploy(oracle.address)
        await exaFront.deployed()

        // We have to enable all the Exafins in the ExaFront
        await Promise.all(Array.from(tokensCollateralRate.keys()).map(async tokenName => {
            const totalSupply = ethers.utils.parseUnits("100000000000", 18);
            const SomeToken = await ethers.getContractFactory("SomeToken")
            const underlyingToken = await SomeToken.deploy("Fake " + tokenName, "F" + tokenName, totalSupply.toString())
            await underlyingToken.deployed()

            const Exafin = await ethers.getContractFactory("Exafin")
            const exafin = await Exafin.deploy(underlyingToken.address, tokenName, exaFront.address)
            await exafin.deployed();
            await exafin.transferOwnership(exaFront.address);

            // Mock PriceOracle setting dummy price
            await oracle.setPrice(tokenName, tokensUSDPrice.get(tokenName))
            // Enable Market for Exafin-TOKEN by setting the collateral rates
            await exaFront.enableMarket(exafin.address, tokensCollateralRate.get(tokenName))

            // Handy maps with all the exafins and underlying tokens
            exafinContracts.set(tokenName, exafin)
            underlyingContracts.set(tokenName, underlyingToken)
        }))

        return new Promise<ExactlyEnv>((resolve) => {
            resolve(new ExactlyEnv(oracle, exaFront, exafinContracts, underlyingContracts))
        })
    }
}

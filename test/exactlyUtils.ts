import { Contract, BigNumber, ContractTransaction, ContractReceipt } from "ethers"

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

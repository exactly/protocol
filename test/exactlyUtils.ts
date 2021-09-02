import { Contract, BigNumber, ethers } from "ethers"
import { poll } from "ethers/lib/utils";

export interface BorrowEventInterface {
    borrowAddress: string;
    borrowAmount: BigNumber;
    borrowCommission: BigNumber;
    borrowMaturity: BigNumber;
}

export interface LendEventInterface {
    lendAddress: string;
    lendAmount: BigNumber;
    lendCommission: BigNumber;
    lendMaturity: BigNumber;
}

export function newBorrowEventListener(exafin: Contract) { 
    return new Promise<BorrowEventInterface>((resolve, reject) => {
        exafin.on('Borrowed', (borrowAddress: string, borrowedAmount: BigNumber, borrowedCommission: BigNumber, borrowMaturity: BigNumber, event) => {
            event.removeListener();
    
            resolve({
                borrowAddress: borrowAddress,
                borrowAmount: borrowedAmount,
                borrowCommission: borrowedCommission,
                borrowMaturity: borrowMaturity
            });
        });
    
        setTimeout(() => {
            reject(new Error('timeout'));
        }, 60000)
    });
}

export function newLendEventListener(exafin: Contract) {
    return new Promise<LendEventInterface>((resolve, reject) => {
        exafin.on('Lent', (lendAddress: string, lendAmount: BigNumber, lendCommission: BigNumber, lendMaturity: BigNumber, event) => {
            event.removeListener();

            resolve({
                lendAddress: lendAddress,
                lendAmount: lendAmount,
                lendCommission: lendCommission,
                lendMaturity: lendMaturity
            });
        });

        setTimeout(() => {
            reject(new Error('timeout'));
        }, 60000)
    });
}

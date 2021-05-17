import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";
import { MockProvider } from 'ethereum-waffle';
import { Contract } from "ethers"

describe("Lender", function() {
    let lender: Contract

    beforeEach(async () => {
        const Lender = await ethers.getContractFactory("Lender");
        lender = await Lender.deploy();
    })

    it("Should increase balance when pooling", async function() {
        await lender.pool(1, { value: 50 });
        expect(await lender.balance()).to.equal(1);
        await lender.pool(1, { value: 50 });
        expect(await lender.balance()).to.equal(2);
    });

    it("Should decrease to 0", async function() {
        await lender.pool(1, { value: 50 });
        expect(await lender.balance()).to.equal(1);
        expect(await lender.withdraw(1));
        expect(await lender.balance()).to.equal(0);
    });

    it("Should revert because not enough funds", async function() {
        await lender.pool(1, { value: 50 });
        expect(await lender.balance()).to.equal(1);
        expect(lender.withdraw(2)).to.be.reverted;
    });

});

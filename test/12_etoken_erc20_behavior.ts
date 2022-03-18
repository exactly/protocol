import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "ethers/lib/utils";
import { Contract } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("EToken ERC20 Behavior", () => {
  let tokenOwner: SignerWithAddress;
  let account: SignerWithAddress;
  let anotherAccount: SignerWithAddress;
  let token: Contract;
  let mockAuditor: Contract;

  const { AddressZero } = ethers.constants;
  const name = "eToken DAI";
  const symbol = "eDAI";

  const initialSupply = parseUnits("100");

  beforeEach(async function () {
    [tokenOwner, account, anotherAccount] = await ethers.getSigners();

    const EToken = await ethers.getContractFactory("EToken");
    token = await EToken.deploy(name, symbol, "18");
    await token.deployed();

    const MockAuditor = await ethers.getContractFactory("MockAuditor");
    mockAuditor = await MockAuditor.deploy();

    await token.initialize(tokenOwner.address, mockAuditor.address); // We simulate that the address of user tokenOwner is the fixedLender contract
    await token.mint(tokenOwner.address, initialSupply);
  });

  describe("total supply", function () {
    it("returns the total amount of tokens", async function () {
      expect(await token.totalSupply()).to.be.equal(initialSupply);
    });
  });

  describe("balanceOf", function () {
    describe("when the requested account has no tokens", function () {
      it("returns zero", async function () {
        expect(await token.balanceOf(anotherAccount.address)).to.be.equal("0");
      });
    });

    describe("when the requested account has some tokens", function () {
      it("returns the total amount of tokens", async function () {
        expect(await token.balanceOf(tokenOwner.address)).to.be.equal(initialSupply);
      });
    });
  });

  describe("transfer", function () {
    describe("when the recipient is not the zero address", function () {
      describe("when the sender does not have enough balance", function () {
        const amount = initialSupply.add(parseUnits("1"));

        it("reverts", async function () {
          await expect(token.transfer(account.address, amount)).to.be.revertedWith("ERC20: balance exceeded");
        });
      });

      describe("when the sender transfers all balance", function () {
        const amount = initialSupply;

        it("transfers the requested amount", async function () {
          await token.transfer(account.address, amount);

          expect(await token.balanceOf(tokenOwner.address)).to.be.equal("0");

          expect(await token.balanceOf(account.address)).to.be.equal(amount);
        });

        it("emits a transfer event", async function () {
          await expect(await token.transfer(account.address, amount))
            .to.emit(token, "Transfer")
            .withArgs(tokenOwner.address, account.address, amount);
        });
      });
    });

    describe("when the sender transfers zero tokens", function () {
      const amount = parseUnits("0");

      it("transfers the requested amount", async function () {
        await token.transfer(account.address, amount);

        expect(await token.balanceOf(tokenOwner.address)).to.be.equal(initialSupply);

        expect(await token.balanceOf(account.address)).to.be.equal("0");
      });

      it("emits a transfer event", async function () {
        await expect(await token.transfer(account.address, amount))
          .to.emit(token, "Transfer")
          .withArgs(tokenOwner.address, account.address, amount);
      });
    });
    describe("when the recipient is the zero address", function () {
      it("reverts", async function () {
        await expect(token.transfer(AddressZero, initialSupply)).to.be.revertedWith("ERC20: zero address");
      });
    });
  });

  describe("transfer from", function () {
    describe("when the token owner is not the zero address", function () {
      describe("when the recipient is not the zero address", function () {
        describe("when the spender has enough approved balance", function () {
          beforeEach(async function () {
            await token.connect(tokenOwner).approve(account.address, initialSupply);
          });

          describe("when the token owner has enough balance", function () {
            const amount = initialSupply;

            it("transfers the requested amount", async function () {
              await token.connect(account).transferFrom(tokenOwner.address, anotherAccount.address, amount);

              expect(await token.balanceOf(tokenOwner.address)).to.be.equal("0");

              expect(await token.balanceOf(anotherAccount.address)).to.be.equal(amount);
            });

            it("decreases the spender allowance", async function () {
              await token.connect(account).transferFrom(tokenOwner.address, anotherAccount.address, amount);

              expect(await token.allowance(tokenOwner.address, account.address)).to.be.equal("0");
            });

            it("emits a transfer event", async function () {
              await expect(
                await token.connect(account).transferFrom(tokenOwner.address, anotherAccount.address, amount),
              )
                .to.emit(token, "Transfer")
                .withArgs(tokenOwner.address, anotherAccount.address, amount);
            });

            it("emits an approval event", async function () {
              await expect(
                await token.connect(account).transferFrom(tokenOwner.address, anotherAccount.address, amount),
              )
                .to.emit(token, "Approval")
                .withArgs(
                  tokenOwner.address,
                  account.address,
                  await token.allowance(tokenOwner.address, account.address),
                );
            });
          });

          describe("when the token owner does not have enough balance", function () {
            const amount = initialSupply.add(parseUnits("1"));

            it("reverts", async function () {
              await expect(
                token.connect(account).transferFrom(tokenOwner.address, anotherAccount.address, amount),
              ).to.be.revertedWith("ERC20: balance exceeded");
            });
          });
        });

        describe("when the spender does not have enough approved balance", function () {
          beforeEach(async function () {
            await token.connect(tokenOwner).approve(account.address, initialSupply.sub(parseUnits("1")));
          });

          describe("when the token owner has enough balance", function () {
            const amount = initialSupply;

            it("reverts", async function () {
              await expect(
                token.connect(account).transferFrom(tokenOwner.address, anotherAccount.address, amount),
              ).to.be.revertedWith("ERC20: allowance exceeded");
            });
          });

          describe("when the token owner does not have enough balance", function () {
            const amount = initialSupply.add(parseUnits("1"));

            it("reverts", async function () {
              await expect(
                token.connect(account).transferFrom(tokenOwner.address, anotherAccount.address, amount),
              ).to.be.revertedWith("ERC20: balance exceeded");
            });
          });
        });
      });

      describe("when the recipient is the zero address", function () {
        const amount = initialSupply;

        beforeEach(async function () {
          await token.connect(tokenOwner).approve(account.address, amount);
        });

        it("reverts", async function () {
          await expect(token.connect(account).transferFrom(tokenOwner.address, AddressZero, amount)).to.be.revertedWith(
            "ERC20: zero address",
          );
        });
      });
    });

    describe("when the token owner is the zero address", function () {
      const amount = 0;

      it("reverts", async function () {
        await expect(token.connect(account).transferFrom(AddressZero, account.address, amount)).to.be.revertedWith(
          "ERC20: zero address",
        );
      });
    });
  });
  describe("approve", function () {
    describe("when the spender is not the zero address", function () {
      describe("when the sender has enough balance", function () {
        const amount = initialSupply;

        it("emits an approval event", async function () {
          await expect(await token.approve(account.address, amount))
            .to.emit(token, "Approval")
            .withArgs(tokenOwner.address, account.address, amount);
        });

        describe("when there was no approved amount before", function () {
          it("approves the requested amount", async function () {
            await token.approve(account.address, amount);

            expect(await token.allowance(tokenOwner.address, account.address)).to.be.equal(amount);
          });
        });

        describe("when the spender had an approved amount", function () {
          beforeEach(async function () {
            await token.approve(account.address, parseUnits("1"));
          });

          it("approves the requested amount and replaces the previous one", async function () {
            await token.approve(account.address, initialSupply);

            expect(await token.allowance(tokenOwner.address, account.address)).to.be.equal(initialSupply);
          });
        });
      });

      describe("when the sender does not have enough balance", function () {
        const amount = initialSupply.add(parseUnits("1"));

        it("emits an approval event", async function () {
          await expect(await token.approve(account.address, amount))
            .to.emit(token, "Approval")
            .withArgs(tokenOwner.address, account.address, amount);
        });

        describe("when there was no approved amount before", function () {
          it("approves the requested amount", async function () {
            await token.approve(account.address, amount);

            expect(await token.allowance(tokenOwner.address, account.address)).to.be.equal(amount);
          });
        });

        describe("when the spender had an approved amount", function () {
          beforeEach(async function () {
            await token.approve(account.address, parseUnits("1"));
          });

          it("approves the requested amount and replaces the previous one", async function () {
            await token.approve(account.address, initialSupply);

            expect(await token.allowance(tokenOwner.address, account.address)).to.be.equal(initialSupply);
          });
        });
      });
    });

    describe("when the spender is the zero address", function () {
      it("reverts", async function () {
        await expect(token.approve(AddressZero, initialSupply)).to.be.revertedWith("ERC20: zero address");
      });
    });
  });
});

import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

// const {
//   shouldBehaveLikeERC20,
//   shouldBehaveLikeERC20Transfer,
//   shouldBehaveLikeERC20Approve,
// } = require("./12_etoken_erc20_behavior.ts");

describe("EToken ERC20 API", () => {
  let initialHolder: SignerWithAddress;
  let recipient: SignerWithAddress;
  let spenderAddress: string;
  let token: Contract;

  const { AddressZero } = ethers.constants;
  const name = "eToken DAI";
  const symbol = "eDAI";

  const initialSupply = parseUnits("100");

  beforeEach(async function () {
    [initialHolder, recipient] = await ethers.getSigners();
    spenderAddress = recipient.address;

    const EToken = await ethers.getContractFactory("EToken");
    token = await EToken.deploy(name, symbol);
    await token.deployed();
    await token.setFixedLender(initialHolder.address); // We simulate that the address of user initialHolder is the fixedLender contact
    await token.mint(initialHolder.address, initialSupply);
  });

  it("has a name", async function () {
    expect(await token.name()).to.equal(name);
  });

  it("has a symbol", async function () {
    expect(await token.symbol()).to.equal(symbol);
  });

  it("has 18 decimals", async function () {
    expect(await token.decimals()).to.be.equal(18);
  });

  // shouldBehaveLikeERC20(
  //   "ERC20",
  //   initialSupply,
  //   initialHolder,
  //   recipient,
  //   anotherAccount
  // );

  describe("decrease allowance", function () {
    describe("when the spender is not the zero address", function () {
      function shouldDecreaseApproval(amount: any) {
        describe("when there was no approved amount before", function () {
          it("reverts", async function () {
            await expect(
              token
                .connect(initialHolder)
                .decreaseAllowance(spenderAddress, amount)
            ).to.be.revertedWith("ERC20: decreased allowance below zero");
          });
        });

        describe("when the spender had an approved amount", function () {
          const approvedAmount = amount;

          beforeEach(async function () {
            await token
              .connect(initialHolder)
              .approve(spenderAddress, approvedAmount);
          });

          it("emits an approval event", async function () {
            await expect(
              await token
                .connect(initialHolder)
                .decreaseAllowance(spenderAddress, approvedAmount)
            )
              .to.emit(token, "Approval")
              .withArgs(initialHolder.address, spenderAddress, parseUnits("0"));
          });

          it("decreases the spender allowance subtracting the requested amount", async function () {
            await token
              .connect(initialHolder)
              .decreaseAllowance(
                spenderAddress,
                approvedAmount.sub(parseUnits("1"))
              );

            expect(
              await token.allowance(initialHolder.address, spenderAddress)
            ).to.be.equal(parseUnits("1"));
          });

          it("sets the allowance to zero when all allowance is removed", async function () {
            await token
              .connect(initialHolder)
              .decreaseAllowance(spenderAddress, approvedAmount);
            expect(
              await token.allowance(initialHolder.address, spenderAddress)
            ).to.be.equal(parseUnits("0"));
          });

          it("reverts when more than the full allowance is removed", async function () {
            await expect(
              token
                .connect(initialHolder)
                .decreaseAllowance(spenderAddress, amount.add(parseUnits("1")))
            ).to.be.revertedWith("ERC20: decreased allowance below zero");
          });
        });
      }

      describe("when the sender has enough balance", function () {
        const amount = initialSupply;

        shouldDecreaseApproval(amount);
      });

      describe("when the sender does not have enough balance", function () {
        const amount = initialSupply.add(parseUnits("1"));

        shouldDecreaseApproval(amount);
      });
    });

    describe("when the spender is the zero address", function () {
      const amount = initialSupply;

      it("reverts", async function () {
        await expect(
          token.connect(initialHolder).decreaseAllowance(AddressZero, amount)
        ).to.be.revertedWith("ERC20: decreased allowance below zero");
      });
    });
  });

  describe("increase allowance", function () {
    const amount = initialSupply;

    describe("when the spender is not the zero address", function () {
      describe("when the sender has enough balance", function () {
        it("emits an approval event", async function () {
          await expect(
            await token
              .connect(initialHolder)
              .increaseAllowance(spenderAddress, amount)
          )
            .to.emit(token, "Approval")
            .withArgs(initialHolder.address, spenderAddress, amount);
        });

        describe("when there was no approved amount before", function () {
          it("approves the requested amount", async function () {
            await token
              .connect(initialHolder)
              .increaseAllowance(spenderAddress, amount);

            expect(
              await token.allowance(initialHolder.address, spenderAddress)
            ).to.be.equal(amount);
          });
        });

        describe("when the spender had an approved amount", function () {
          beforeEach(async function () {
            await token
              .connect(initialHolder)
              .approve(spenderAddress, parseUnits("1"));
          });

          it("increases the spender allowance adding the requested amount", async function () {
            await token
              .connect(initialHolder)
              .increaseAllowance(spenderAddress, amount);

            expect(
              await token.allowance(initialHolder.address, spenderAddress)
            ).to.be.equal(amount.add(parseUnits("1")));
          });
        });
      });

      describe("when the sender does not have enough balance", function () {
        const amount = initialSupply.add(parseUnits("1"));

        it("emits an approval event", async function () {
          await expect(
            await token
              .connect(initialHolder)
              .increaseAllowance(spenderAddress, amount)
          )
            .to.emit(token, "Approval")
            .withArgs(initialHolder.address, spenderAddress, amount);
        });

        describe("when there was no approved amount before", function () {
          it("approves the requested amount", async function () {
            await token
              .connect(initialHolder)
              .increaseAllowance(spenderAddress, amount);

            expect(
              await token.allowance(initialHolder.address, spenderAddress)
            ).to.be.equal(amount);
          });
        });

        describe("when the spender had an approved amount", function () {
          beforeEach(async function () {
            await token
              .connect(initialHolder)
              .approve(spenderAddress, parseUnits("1"));
          });

          it("increases the spender allowance adding the requested amount", async function () {
            await token
              .connect(initialHolder)
              .increaseAllowance(spenderAddress, amount);

            expect(
              await token.allowance(initialHolder.address, spenderAddress)
            ).to.be.equal(amount.add(parseUnits("1")));
          });
        });
      });
    });

    describe("when the spender is the zero address", function () {
      const spenderAddress = AddressZero;

      it("reverts", async function () {
        await expect(
          token.connect(initialHolder).increaseAllowance(spenderAddress, amount)
        ).to.be.revertedWith("ERC20: approve to the zero address");
      });
    });
  });

  describe("_mint", function () {
    const amount = parseUnits("50");
    it("rejects a null account", async function () {
      await expect(token.mint(AddressZero, amount)).to.be.revertedWith(
        "ERC20: mint to the zero address"
      );
    });

    let tx: any;
    describe("for a non zero account", function () {
      beforeEach("minting", async function () {
        tx = token.mint(recipient.address, amount);
        await tx;
      });

      it("increments totalSupply", async function () {
        const expectedSupply = initialSupply.add(amount);
        expect(await token.totalSupply()).to.be.equal(expectedSupply);
      });

      it("increments recipient balance", async function () {
        expect(await token.balanceOf(recipient.address)).to.be.equal(amount);
      });

      it("emits Transfer event", async function () {
        await expect(tx)
          .to.emit(token, "Transfer")
          .withArgs(AddressZero, recipient.address, amount);
      });
    });
  });

  describe("_burn", function () {
    it("rejects a null account", async function () {
      await expect(token.burn(AddressZero, parseUnits("1"))).to.be.revertedWith(
        "ERC20: burn from the zero address"
      );
    });

    describe("for a non zero account", function () {
      it("rejects burning more than balance", async function () {
        await expect(
          token.burn(initialHolder.address, initialSupply.add(parseUnits("1")))
        ).to.be.revertedWith("ERC20: burn amount exceeds balance");
      });

      const describeBurn = function (description: string, amount: any) {
        describe(description, function () {
          let tx: any;
          beforeEach("burning", async function () {
            tx = token
              .connect(initialHolder)
              .burn(initialHolder.address, amount);
            await tx;
          });

          it("decrements totalSupply", async function () {
            const expectedSupply = initialSupply.sub(amount);
            expect(await token.totalSupply()).to.be.equal(expectedSupply);
          });

          it("decrements initialHolder balance", async function () {
            const expectedBalance = initialSupply.sub(amount);
            expect(await token.balanceOf(initialHolder.address)).to.be.equal(
              expectedBalance
            );
          });

          it("emits Transfer event", async function () {
            await expect(tx)
              .to.emit(token, "Transfer")
              .withArgs(initialHolder.address, AddressZero, amount);
          });
        });
      };

      describeBurn("for entire balance", initialSupply);
      describeBurn(
        "for less amount than balance",
        initialSupply.sub(parseUnits("1"))
      );
    });
  });

  //   describe("_transfer", function () {
  //     shouldBehaveLikeERC20Transfer(
  //       "ERC20",
  //       initialHolder,
  //       recipient,
  //       initialSupply,
  //       function (from: any, to: any, amount: any) {
  //         return token.transferInternal(from, to, amount);
  //       }
  //     );

  //     describe("when the sender is the zero address", function () {
  //       it("reverts", async function () {
  //         await expect(
  //           token.transferInternal(AddressZero, recipient.address, initialSupply)
  //         ).to.be.revertedWith("ERC20: transfer from the zero address");
  //       });
  //     });
  //   });

  //   describe("_approve", function () {
  //     shouldBehaveLikeERC20Approve(
  //       "ERC20",
  //       initialHolder,
  //       recipient,
  //       initialSupply,
  //       function (owner: any, spender: any, amount: any) {
  //         return token.approveInternal(owner, spender, amount);
  //       }
  //     );

  //     describe("when the owner is the zero address", function () {
  //       it("reverts", async function () {
  //         await expect(
  //           token.approveInternal(AddressZero, recipient.address, initialSupply)
  //         ).to.be.revertedWith("ERC20: approve from the zero address");
  //       });
  //     });
  //   });
});

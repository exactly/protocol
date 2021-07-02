import { BigNumber, BigNumberish } from 'ethers'
import { expect } from "chai"

export class DSSMath {

  static UNIT: BigNumber = BigNumber.from(10).pow(BigNumber.from(27)) // RAY

  /// @dev Converts a BigNumber
  static bnify(num: BigNumberish): BigNumber {
    return BigNumber.from(num.toString())
  }

  /// @dev Converts a BigNumberish to WAD precision, for BigNumberish up to 10 decimal places
  static toWad(value: BigNumberish): BigNumber {
    let exponent = BigNumber.from(10).pow(BigNumber.from(8))
    return BigNumber.from((value as any) * 10 ** 10).mul(exponent)
  }

  /// @dev Converts a BigNumberish to RAY precision, for BigNumberish up to 10 decimal places
  static toRay(value: BigNumberish): BigNumber {
    let exponent = BigNumber.from(10).pow(BigNumber.from(17))
    return BigNumber.from((value as any) * 10 ** 10).mul(exponent)
  }

  /// @dev Converts a BigNumberish to RAD precision, for BigNumberish up to 10 decimal places
  static toRad(value: BigNumberish): BigNumber {
    let exponent = BigNumber.from(10).pow(BigNumber.from(35))
    return BigNumber.from((value as any) * 10 ** 10).mul(exponent)
  }

  /// @dev Adds two BigNumberishs
  /// I.e. addBN(ray(x), ray(y)) = ray(x + y)
  static addBN(x: BigNumberish, y: BigNumberish): BigNumber {
    return BigNumber.from(x).add(BigNumber.from(y))
  }

  /// @dev Substracts a BigNumberish from another
  /// I.e. subBN(ray(x), ray(y)) = ray(x - y)
  static subBN(x: BigNumberish, y: BigNumberish): BigNumber {
    return BigNumber.from(x).sub(BigNumber.from(y))
  }

  /// @dev Multiplies a BigNumberish in any precision by a BigNumberish in RAY precision, with the output in the first parameter's precision.
  /// I.e. mulRay(wad(x), ray(y)) = wad(x*y)
  static mulRay(x: BigNumberish, ray: BigNumberish): BigNumber {
    return BigNumber.from(x).mul(BigNumber.from(ray)).div(this.UNIT)
  }

  /// @dev Divides x by y, rounding up
  static divrup(x: BigNumber, y: BigNumber): BigNumber {
    const z = BigNumber.from(x).mul(10).div(BigNumber.from(y))
    if (z.mod(10).gt(0)) return z.div(10).add(1)
    return z.div(10)
  }

  // Checks if 2 bignumberish are almost-equal with up to `precision` room for wiggle which by default is 1
  static almostEqual(x: BigNumberish, y: BigNumberish, precision: BigNumberish = 1) {
    x = this.bnify(x)
    y = this.bnify(y)

    if (x.gt(y)) {
      expect(x.sub(y).lte(precision)).to.be.true
    } else {
      expect(y.sub(x).lte(precision)).to.be.true
    }
  }
}

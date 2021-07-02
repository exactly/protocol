import { expect } from "chai"
import { ethers } from "hardhat"
import { DSSMath } from './lib/dssmath'

describe('DSSMath', () => {
  const spot =   '1500000000000000000000000000'
  const rate =   '1250000000000000000000000000'
  const price =  '1200000000000000000000000000' // spot / rate
  const limits = '1000000000000000000000000000000000000000000000'
  const frac =   '1500000000000000000000000000000000000000000000'

  describe('DSSMath.toRay', async () => {
    it('runs toRay', async () => {
      expect(DSSMath.toRay(5).toString()).to.equal('5000000000000000000000000000')
    })

    it('handles decimals', async () => {
      expect(DSSMath.toRay(1.5).toString()).to.equal(spot)
      expect(DSSMath.toRay('1.5').toString()).to.equal(spot)
      expect(DSSMath.toRay('1.25').toString()).to.equal(rate)
      expect(DSSMath.toRay('1.2').toString()).to.equal(price)
    })
  })

  describe('DSSMath.toRad', async () => {
    it('runs toRad', async () => {
      expect(DSSMath.toRad(1).toString()).to.equal(limits)
    })

    it('handles decimals', async () => {
      expect(DSSMath.toRad('1.5').toString()).to.equal(frac)
      expect(DSSMath.toRad(1.5).toString()).to.equal(frac)
    })
  })
})

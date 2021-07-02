
import { BigNumber, BigNumberish } from 'ethers'
import { DSSMath } from './dssmath'
import { formatBytes32String } from 'ethers/lib/utils'

export class MakerLabels {
  public static readonly WETH = formatBytes32String('ETH-A');
  public static readonly upperBoundLineLabelForAll = formatBytes32String('Line');
  public static readonly upperBoundLineLabelForCollateral = formatBytes32String('line');
  public static readonly spotLabel = formatBytes32String('spot');
}

export class MakerDemoValues {
  public static readonly limits: BigNumber = DSSMath.toRad(10000)
  public static readonly spot: BigNumber = DSSMath.toRay(1800)
  public static readonly chi1: BigNumber = DSSMath.toRay(1.10)
  public static readonly rate1: BigNumber = DSSMath.toRay(1.10)
}

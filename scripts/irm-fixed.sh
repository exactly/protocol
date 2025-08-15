#!/usr/bin/env bash

read -ra input <<< "$(cast abi-decode "_()(uint256,int256,int256,int256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" "$1" | sed 's/ .*//' | xargs)"

rate=$(BC_LINE_LENGTH=666 bc -l <<< "
  scale     = 2 * 18

  wad       = 1000000000000000000
  base      = ${input[0]} / wad
  spreadf   = ${input[1]} / wad
  ttmspeed  = ${input[2]} / wad
  tpref     = ${input[3]} / wad
  fixalloc  = ${input[4]} / wad
  maxrate   = ${input[5]} / wad
  maturity  = ${input[6]}
  ufixed    = ${input[7]} / wad
  uglobal   = ${input[8]} / wad
  timestamp = ${input[9]}
  maturityallocation = ${input[10]} / wad
  maturityallocationnext = ${input[11]} / wad
  fixedborrowthreshold = ${input[12]} / wad
  minthresholdfactor = ${input[13]} / wad
  maxfuturepools = 12

  if (uglobal == 0) {
    rate = base
  } else {
    y = ((uglobal * wad) * (fixedborrowthreshold * minthresholdfactor / maxfuturepools + maturityallocation - maturityallocationnext) * wad)
    if (y > wad) {
      y = (uglobal * (fixedborrowthreshold * minthresholdfactor / maxfuturepools + maturityallocation - maturityallocationnext))
      oldscale = scale
      scale = 18
      y = (y + 0.000000000000000001) / 1
      scale = oldscale
      sqalpha   = maturityallocation / y
      sqx       = ufixed / y
    } else {
      sqalpha   = maturityallocation * wad
      sqx       = ufixed * wad
    }

    alpha     = sqrt(sqalpha)
    a         = (2 - sqalpha) / (alpha * (1 - alpha))
    x         = sqrt(sqx)
    z         = a * x + (1 - a) * sqx - 1

    ttm       = maturity - timestamp
    interval  = 4 * 7 * 24 * 60 * 60

    scale     = 0
    scale     = 2 * 18
    ttmaxm    = maxfuturepools * interval
    
    rate      = base * (1 + e(ttmspeed * l(ttm/ttmaxm)) * (tpref + spreadf * z))
  }

  if (rate > maxrate) {
    rate  = maxrate
  }

  scale       = 0
  print rate * wad / 1
")

cast --to-uint256 -- "$rate" | tr -d '\n'

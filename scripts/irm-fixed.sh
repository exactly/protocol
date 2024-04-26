#!/usr/bin/env bash

read -ra input <<< "$(cast abi-decode "_()(uint256,int256,int256,int256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" "$1" | sed 's/ .*//' | xargs)"

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
  maxpools  = ${input[7]}
  ufixed    = ${input[8]} / wad
  uglobal   = ${input[9]} / wad
  timestamp = ${input[10]}

  if (uglobal == 0) {
    rate      = base
  } else {
    sqalpha   = maxpools / fixalloc
    alpha     = sqrt(sqalpha)
    sqx       = maxpools * ufixed / (uglobal * fixalloc)
    x         = sqrt(sqx)
    a         = (2 - sqalpha) / (alpha * (1 - alpha))
    z         = a * x + (1 - a) * sqx - 1

    ttm       = maturity - timestamp
    interval  = 4 * 7 * 24 * 60 * 60

    scale     = 0
    scale     = 2 * 18
    ttmaxm    = maxpools * interval
    
    rate      = base * (1 + e(ttmspeed * l(ttm/ttmaxm)) * (tpref + spreadf * z))
  }

  if (rate > maxrate) {
    rate  = maxrate
  }

  scale       = 0
  print rate * wad / 1
")

cast --to-uint256 -- "$rate" | tr -d '\n'

#!/usr/bin/env bash

read -ra input <<< "$(cast abi-decode "_()(uint256,uint256,uint256,int256,int256,uint256,uint256,uint256,uint256,uint256)" "$1" | sed 's/ .*//' | xargs)"

rate=$(bc -l <<< "
  scale     = 2 * 18

  wad       = 1000000000000000000
  ufixed    = ${input[0]} / wad
  uglobal   = ${input[1]} / wad
  fixedunat = ${input[2]} / wad
  base      = ${input[3]} / wad
  ttmspeed  = ${input[4]} / wad
  spreadf   = ${input[5]} / wad
  tpref     = ${input[6]} / wad
  maxpools  = ${input[7]}
  maturity  = ${input[8]}
  timestamp = ${input[9]}

  if (ufixed == 0) rate = base
  else {
    sqalpha   = maxpools / fixedunat
    alpha     = sqrt(sqalpha)
    sqx       = maxpools * ufixed / (uglobal * fixedunat)
    x         = sqrt(sqx)
    a         = (2 - sqalpha) / (alpha * (1 - alpha))
    z         = a * x + (1 - a) * sqx - 1

    ttm       = maturity - timestamp
    interval  = 4 * 7 * 24 * 60 * 60
    ttmaxm    = timestamp - (timestamp % interval) + maxpools * interval
    
    rate      = base * (1 + e(ttmspeed * l(ttm/ttmaxm)) * (tpref + spreadf * z))
  }
  scale       = 0
  print rate * wad / 1
")

cast --to-int256 -- "$rate" | tr -d '\n'

#!/usr/bin/env bash

read -ra input <<< "$(cast abi-decode "_()(uint256,uint256,uint256,int256,uint256,uint256,uint256,uint256)" "$1" | sed 's/ .*//' | xargs)"

rate=$(bc -l <<< "
  scale     = 2 * 18

  wad       = 1000000000000000000
  ufloating = ${input[0]} / wad
  uglobal   = ${input[1]} / wad
  unat      = ${input[2]} / wad
  a         = ${input[3]} / wad
  b         = ${input[4]} / wad
  umax      = ${input[5]} / wad
  sspeed    = ${input[6]} / wad
  gspeed    = ${input[7]} / wad
  
  r = a / (umax - ufloating) + b

  if (uglobal == 1) rate = 0
  else if (uglobal == 0) rate = r
  else if (uglobal >= ufloating) {
    sig     = 1 / (1 + e(-sspeed * (l(uglobal / (1 - uglobal)) - l(unat / (1 - unat)))))
    rate    = e(-gspeed * l(1 - sig * uglobal)) * r
  }

  scale     = 0
  print rate * wad / 1
")

cast --to-int256 -- "$rate" | tr -d '\n'

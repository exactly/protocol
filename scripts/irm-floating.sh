#!/usr/bin/env bash

read -ra input <<< "$(cast abi-decode "_()(uint256,int256,uint256,uint256,int256,int256,uint256,uint256,uint256)" "$1" | sed 's/ .*//' | xargs)"

rate=$(bc -l <<< "
  scale     = 2 * 18

  wad       = 1000000000000000000
  a         = ${input[0]} / wad
  b         = ${input[1]} / wad
  umax      = ${input[2]} / wad
  unat      = ${input[3]} / wad
  gspeed    = ${input[4]} / wad
  sspeed    = ${input[5]} / wad
  maxrate   = ${input[6]} / wad
  ufloating = ${input[7]} / wad
  uglobal   = ${input[8]} / wad
    
  r = a / (umax - ufloating) + b

  if (uglobal >= 1) {
    rate    = maxrate
  } else if (uglobal == 0) {
    rate    = r
  } else if (uglobal >= ufloating) {
    sig     = 1 / (1 + e(-sspeed * (l(uglobal / (1 - uglobal)) - l(unat / (1 - unat)))))
    rate    = e(-gspeed * l(1 - sig * uglobal)) * r
  }

  if (rate > maxrate) {
    rate  = maxrate
  }

  scale     = 0
  print rate * wad / 1
")

cast --to-uint256 -- "$rate" | tr -d '\n'

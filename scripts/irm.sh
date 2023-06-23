#!/usr/bin/env bash

read -ra input <<< "$(cast abi-decode "_()(uint256,uint256,uint256,int256,uint256)" "$1" | sed 's/ .*//' | xargs)"

rate=$(bc -l <<< "
  scale = 2 * 18

  u0   = ${input[0]} / 1000000000000000000
  u1   = ${input[1]} / 1000000000000000000
  a    = ${input[2]} / 1000000000000000000
  b    = ${input[3]} / 1000000000000000000
  umax = ${input[4]} / 1000000000000000000

  if (u0 == u1) {
    rate = a / (umax - u0) + b
  } else {
    rate = a * l((umax - u0) / (umax - u1)) / (u1 - u0) + b
  }

  scale = 0
  print rate * 1000000000000000000 / 1
")

cast --to-int256 -- "$rate" | tr -d '\n'

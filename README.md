# Exactly Protocol

![CI Status](https://github.com/exactly/protocol/actions/workflows/test.yml/badge.svg)
[![codecov](https://codecov.io/gh/exactly/protocol/branch/main/graph/badge.svg)](https://codecov.io/gh/exactly/protocol)

```text
 ______     __  __     ______     ______     ______   __         __  __    
/\  ___\   /\_\_\_\   /\  __ \   /\  ___\   /\__  _\ /\ \       /\ \_\ \   
\ \  __\   \/_/\_\/_  \ \  __ \  \ \ \____  \/_/\ \/ \ \ \____  \ \____ \  
 \ \_____\   /\_\/\_\  \ \_\ \_\  \ \_____\    \ \_\  \ \_____\  \/\_____\ 
  \/_____/   \/_/\/_/   \/_/\/_/   \/_____/     \/_/   \/_____/   \/_____/ 
                                                                           
```

This repository contains the smart contracts source code and markets configuration for Exactly Protocol.

## What is Exactly?

Exactly is a decentralized and open-source DeFi protocol that allows users to easily exchange the value of their crypto assets through deposits and borrows with variable and fixed interest rates.

Unlike other fixed rate protocols that determine fixed rates based on the price of various maturity tokens, Exactly Protocol is the first to determine fixed rates based on the utilization rate of pools with different maturity dates. This means the protocol does not need a custom AMM to trade maturity tokens; it only needs a variable rate pool that consistently provides liquidity to the different fixed rate pools.

Our ultimate goal is to democratize the credit market by making it accessible to people everywhere. We will establish fixed rates, optimize scalability, and partner with neo-banks and digital wallets to achieve this. By doing so, we aim to empower individuals and communities worldwide to access fair and transparent credit opportunities.

## Project Links

- [Website](https://exact.ly/)
- [Twitter](https://twitter.com/exactlyprotocol/)
- [Discord](https://exact.ly/discord)
- [Medium](https://medium.com/@exactly_protocol)
- [Docs](https://docs.exact.ly)
- [White Paper](https://docs.exact.ly/getting-started/white-paper)
- [Math Paper](https://docs.exact.ly/getting-started/math-paper)
- [Audits](https://docs.exact.ly/security/audits)

## Community

You can join the [Discord](https://exact.ly/discord) channel to ask questions about the protocol or talk about Exactly with other peers.

## Setup

### Clone

```bash
git clone git@github.com:exactly/protocol.git
```

### Install Locally

```bash
yarn
```

### Run Tests

```bash
yarn test
```

### Run Coverage

```bash
yarn coverage
```

### Gas Reports

```bash
REPORT_GAS=1 yarn test
```

### Deploy

```bash
yarn deploy:op-sepolia
```

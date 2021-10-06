# Exactly.finance Protocol v0.1

![CI Status](https://github.com/exactly-finance/protocol/actions/workflows/main.yml/badge.svg)
[![codecov](https://codecov.io/gh/exactly-finance/protocol/branch/main/graph/badge.svg?token=qYngTpvXBT)](https://codecov.io/gh/exactly-finance/protocol)


## Clone

```bash
mkdir -p ~/dev/exactly && cd ~/dev/exactly
git clone git@github.com:exactly-finance/protocol.git
```

## Install Locally

```bash
npm install
```

## Add Environment Variables

Create a file in the root of the project and name it `.env`. You will nedd to have the following keys

```bash
MNEMONIC=
ALKEMY_MAINNET_API_KEY=
ALKEMY_RINKEBY_API_KEY=
PUBLIC_ADDRESS=
```

To get a new **mnemonic** you can do it with `npx mnemonics`, take into account that this mnemonic is only for development and testing.

For the Alchemy API keys you can create a free account in: `https://alchemyapi.io` and create both MAINNET and RINKEBY accounts.

The PUBLIC_ADDRESS is used to send you some tokens so you can test the whole project.

## Run Local Node

```bash
npx hardhat node
```

## Run Tests

```bash
npx hardhat test
```

## Run Coverate

```bash
npx hardhat coverage
```

## Deploy

```bash
echo "YOUR_PRIVATE_KEY" > .secret
npx hardhat deploy --network rinkeby
```

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

Create an `.env`, using the example:

```
cp .env.example .env
```

You will then need to set the following keys there:

* `MNEMONIC`: a valid bip39 mnemonic from which accounts will be generated. To get a new one you can do it with `npx mnemonics`, taking into account that this mnemonic is only for development and testing.
* `ALCHEMY_RINKEBY_API_KEY`: API key linked to a rinkeby alchemy project, used to directly connect to the network
* `ALCHEMY_KOVAN_API_KEY`: API key linked to a kovan alchemy project, used to directly connect to the network
* `FORKING`: `true` if you want to work by forking a mainnet node
* `ALCHEMY_MAINNET_API_KEY`: API key linked to a mainnet alchemy project, used when forking a mainnet node
* `PUBLIC_ADDRESS`: where tokens will be sent so you can play around when in forking mode

For the Alchemy API keys you can create a free account in: `https://alchemyapi.io` and create both MAINNET and RINKEBY accounts.

## Run Local Node
Useful if you want to see the logs explicitly, otherwise hardhat takes care of spinning a node up

```bash
npx hardhat node
```

## Run Tests

```bash
npx hardhat test
```

## Run Coverage

```bash
npx hardhat coverage
```

## Deploy

```bash
npx hardhat deploy --network rinkeby
```

## Docs

you can view them by:
- installing the dependencies with `pip3 install -r requirements.txt`
- calling sphinx: `make singlehtml`
- opening it in `yourbrowser _build/singlehtml/index.html`

Or by using [the hosted version](https://static.capu.tech/other/exactly-rtd/)

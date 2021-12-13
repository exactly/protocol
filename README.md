# Exactly.finance Protocol v0.1

![CI Status](https://github.com/exactly-finance/protocol/actions/workflows/tests.yml/badge.svg)
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
also, run `npm run prepare` so git hooks are configured

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
* `AWS_USER_KEY=`(optional): For uploading addresses on deploy. To get the key you can ask @juanigallo for an AWS user
* `AWS_USER_SECRET=`(optional): For uploading addresses on deploy. To get the key you can ask @juanigallo for an AWS user

For the Alchemy API keys you can create a free account in: `https://alchemyapi.io` and create both MAINNET and RINKEBY accounts.

## Run Tests

```bash
npx hardhat test
```

## Run Coverage

```bash
npx hardhat coverage
```

## Gas Reports

```bash
export REPORT_GAS=1 && npx hardhat test
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

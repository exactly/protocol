# @exactly/protocol

## 0.2.19

### Patch Changes

- e9c2406: 📄 escrow: change `EscrowedEXA` license to MIT

## 0.2.18

### Patch Changes

- 5770fa8: 🚀 ethereum: deploy new `WBTC` irm
- bd4a216: 🚀 optimism: deploy `WBTC` market

## 0.2.17

### Patch Changes

- ab123c1: 🔥 escrow: drop unchained initializers
- 6179c24: 📝 escrow: add missing natspec
- 11d82f2: 🚚 deployments: rename `esEXA`
- 2cd9c82: 🔒 escrow: validate streams on cancel and withdraw
- e766ecf: 🚀 optimism: deploy vote previewer beefy support
- 4e319bf: ✨ vote: get power from beefy
- 2d882d6: 🚸 escrow: receive `maxRatio` and `maxPeriod` on vesting
- 8938c27: 🚀 optimism: deploy escrow upgrade
- 0182437: 🚸 escrow: return reserve on external stream cancel
- 3b40526: ✨ vote: get voting power from velodrome and extra
- 686c503: 🚀 optimism: deploy vote previewer
- a0f4889: 🔥 escrow: drop internal `_cancel`

## 0.2.16

### Patch Changes

- c45406d: 🔧 deployments: set actual abi for each asset
- f483484: ✨ escrow: escrow and vest exa
- 375b367: 🚀 optimism: deploy market upgrade
- f483484: 🐛 debt-manager: fix allowance denomination in shares
- f5eadf5: ✨ swapper: swap `ETH` for `EXA` on velodrome
- 189faaa: 🚀 ethereum: deploy new debt previewer
- b6fd0a7: 🚑️ debt-previewer: fix different reward lengths
- 8522222: 🚀 optimism: deploy new debt previewer
- f483484: 🔥 debt-manager: drop cross-asset features
- 4b01ae7: 🚀 optimism: deploy rewards permit upgrade
- 6d2abe1: 🚑️ previewer: fix different reward lengths
- e9847b1: ✨ rewards: allow claim with signature
- e73bfb2: 🚑 debt-manager: validate markets
- f483484: ✨ debt-manager: check permit surplus
- 4b342d1: 🚀 optimism: deploy new debt manager and escrowed exa
- f940754: 🚀 optimism: deploy previewer rewards hotfix

## 0.2.15

### Patch Changes

- 34d960c: ✨ price-feeds: add pool-based feed
- 0fa8b19: ✨ airdrop: stream `EXA` to eligible accounts
- a1b3de9: 🚀 optimism: deploy airdrop contract
- 8f55002: 🍱 airdrop: add json with accounts and amounts
- 0558b53: 🚀 optimism: deploy `EXA` price feed
- 29f06ef: 🚀 optimism: deploy `EXA`

## 0.2.14

### Patch Changes

- 4f1b6c2: 🚀 optimism: deploy new interest rate models
- d29326e: 🚚 package: rename `mainnet` to `ethereum`
- ba05342: ✨ debt-manager: support cross-leverage
- 59b6d17: ✨ debt-manager: support cross-deleverage
- b2cb7eb: 🚀 ethereum: deploy new interest rate models

## 0.2.13

### Patch Changes

- e2a4b01: 🚀 ethereum: deploy new debt manager
- c4dc9d7: ✨ debt-manager: support `EIP-2612` permit
- 56bf04f: 🚀 optimism: deploy new debt manager
- 9803f19: 🐛 debt-manager: verify flashloan call origin

## 0.2.12

### Patch Changes

- d76c1a3: 🚀 ethereum: deploy debt manager

## 0.2.11

### Patch Changes

- e7a1bb2: 🚚 debt-manager: rename leverager
- 85b5248: 🚀 optimism: deploy debt manager
- e7a1bb2: ✨ debt-manager: add rollover functions

## 0.2.10

### Patch Changes

- 83a1615: 🦺 irm: add max config value checks
- 10ed054: ⚡️ market: remove unnecessary checks
- 1aceca2: 🐛 previewer: fix borrow reward rate calculation
- 84850f9: ⚡️ rewards: perform check earlier
- 4fe8a12: 🎨 market: trigger rewards before `floatingDebt` update
- 7d787e7: ⚡️ rewards: reusing storage pointers
- eef7f82: 🩹 rewards: adjust calculations' roundings
- e17f162: ⚡️ rewards: reusing memory pointers
- f8ab2a6: ⚡️ rewards: hardcode guaranteed boolean values
- 58e498c: 🚀 optimism: deploy `wstETH` market
- 8329997: 🔊 market: emit `RewardsControllerSet` event
- 4b86c35: 👔 market: update floating debt before setting treasury
- 953f33f: 🐛 market: trigger rewards before `floatingDebt` increase
- a27082d: ♻️ rewards: simplify calculations

## 0.2.9

### Patch Changes

- 51eb498: ✨ leverager: add leverage & deleverage functions
- 411e663: 🚀 optimism: deploy rewards system
- 783b0c3: 🐛 market: add missing reward hook calls

## 0.2.8

### Patch Changes

- 78471e6: 🐛 rewards: fix distributionFactor calculation

## 0.2.7

### Patch Changes

- 82c0b95: 🚀 optimism: deploy protocol

## 0.2.6

### Patch Changes

- 801ea3d: 🦺 auditor: get decimals from market
- a60d0ea: 👔 market: use only current utilization for floating rate
- 58ac95f: 🔥 market: remove symbol refresher
- ad1e7a0: ✨ rewards: implement reward system

## 0.2.5

### Patch Changes

- 092d055: 🐛 previewer: fix fixed deposit rate

# @exactly/protocol

## 0.2.13

### Patch Changes

- e2a4b01: 🚀 mainnet: deploy new debt manager
- c4dc9d7: ✨ debt-manager: support `EIP-2612` permit
- 56bf04f: 🚀 optimism: deploy new debt manager
- 9803f19: 🐛 debt-manager: verify flashloan call origin

## 0.2.12

### Patch Changes

- d76c1a3: 🚀 mainnet: deploy debt manager

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

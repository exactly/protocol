use anyhow::{Ok, Result};
use arbiter_core::{math::wad_to_float, middleware::RevmMiddleware};
use ethers::types::{Address, U256};
use log::info;

use crate::bindings::{
    auditor::Auditor,
    market::Market,
    mock_erc20::MockERC20,
    previewer::{MarketAccount, Previewer},
};

pub struct Liquidator<const L: usize> {
    pub auditor: Auditor<RevmMiddleware>,
    pub previewer: Previewer<RevmMiddleware>,
    pub accounts: [Address; L],
}

impl<const L: usize> Liquidator<L> {
    pub async fn new(
        auditor: Auditor<RevmMiddleware>,
        previewer: Previewer<RevmMiddleware>,
        accounts: [Address; L],
    ) -> Result<Self> {
        let client = auditor.client();
        for market in auditor.all_markets().call().await? {
            let asset = MockERC20::new(
                Market::new(market, client.clone()).asset().call().await?,
                client.clone(),
            );
            let amount = U256::exp10(asset.decimals().call().await?.into()) * 10_000_000;
            asset.mint(client.address(), amount).send().await?.await?;
            asset.approve(market, amount).send().await?.await?;
        }
        Ok(Self {
            auditor,
            previewer,
            accounts,
        })
    }

    pub async fn check_liquidations(&self) -> Result<()> {
        for account in &self.accounts {
            let (collateral, debt) = self
                .auditor
                .account_liquidity(*account, Address::zero(), U256::zero())
                .call()
                .await?;
            if collateral >= debt {
                continue;
            }
            info!(
                "account: {}, health factor: {}",
                account,
                if debt == U256::zero() {
                    f64::INFINITY
                } else {
                    wad_to_float(collateral) / wad_to_float(debt)
                }
            );
            let exactly: Vec<MarketAccount> = self.previewer.exactly(*account).call().await?;
            let repay_market = exactly
                .iter()
                .reduce(|a, b| {
                    if (b.floating_borrow_assets
                        + b.fixed_borrow_positions
                            .iter()
                            .fold(U256::zero(), |debt, position| {
                                debt + position.position.principal + position.position.fee
                            }))
                        * b.usd_price
                        / U256::exp10(b.decimals.into())
                        > (a.floating_borrow_assets
                            + a.fixed_borrow_positions.iter().fold(
                                U256::zero(),
                                |debt, position| {
                                    debt + position.position.principal + position.position.fee
                                },
                            ))
                            * a.usd_price
                            / U256::exp10(a.decimals.into())
                    {
                        b
                    } else {
                        a
                    }
                })
                .unwrap()
                .market;
            let seize_market = exactly
                .iter()
                .reduce(|a, b| {
                    if b.is_collateral
                        && b.floating_deposit_assets * b.usd_price / U256::exp10(b.decimals.into())
                            > a.floating_deposit_assets * a.usd_price
                                / U256::exp10(a.decimals.into())
                    {
                        b
                    } else {
                        a
                    }
                })
                .unwrap()
                .market;
            Market::new(repay_market, self.auditor.client().clone())
                .liquidate(*account, U256::MAX, seize_market)
                .send()
                .await?
                .await?;
        }
        Ok(())
    }
}

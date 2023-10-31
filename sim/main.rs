use anyhow::{Ok, Result};
use arbiter_core::{
    environment::builder::{BlockSettings, EnvironmentBuilder},
    middleware::RevmMiddleware,
};
use ethers::types::{Bytes, I256, U128, U256};
use futures::future::try_join_all;
use startup::deploy_market;

use crate::{
    agents::price_changer::PriceProcessParameters,
    bindings::{
        auditor::{Auditor, LiquidationIncentive},
        erc1967_proxy::ERC1967Proxy,
        interest_rate_model::InterestRateModel,
        market::Market,
        mock_erc20::MockERC20,
    },
};

mod agents;
#[allow(unused_imports)]
mod bindings;
mod startup;

#[tokio::main]
pub async fn main() -> Result<()> {
    if std::env::var("RUST_LOG").is_err() {
        std::env::set_var("RUST_LOG", "warn");
    }
    env_logger::init();

    let price_process_params = PriceProcessParameters {
        initial_price: 1.0,
        mean: 1.0,
        std_dev: 0.01,
        theta: 3.0,
        t_0: 0.0,
        t_n: 100.0,
        num_steps: 2_500,
        seed: None,
    };
    let environment = EnvironmentBuilder::new()
        .label("exactly")
        .block_settings(BlockSettings::RandomlySampled {
            block_rate: 1.0,
            block_time: 12,
            seed: 1,
        })
        .build();
    let deployer = RevmMiddleware::new(&environment, Some("deployer"))?;

    let auditor = Auditor::new(
        ERC1967Proxy::deploy(
            deployer.clone(),
            (
                Auditor::deploy(deployer.clone(), U256::from(18))?
                    .send()
                    .await?
                    .address(),
                Bytes::default(),
            ),
        )?
        .send()
        .await?
        .address(),
        deployer.clone(),
    );
    auditor
        .initialize(LiquidationIncentive {
            liquidator: U128::exp10(16).as_u128() * 9,
            lenders: U128::exp10(16).as_u128(),
        })
        .send()
        .await?
        .await?;

    let irm = InterestRateModel::deploy(
        deployer.clone(),
        (
            U256::exp10(15) * 23,
            I256::exp10(14) * -25,
            U256::exp10(16) * 102,
            U256::exp10(15) * 23,
            I256::exp10(14) * -25,
            U256::exp10(16) * 102,
        ),
    )?
    .send()
    .await?;

    let mut markets = try_join_all([("DAI", 18), ("USDC", 6)].map(|(symbol, decimals)| {
        deploy_market(
            symbol,
            decimals,
            deployer.clone(),
            auditor.clone(),
            irm.clone(),
            price_process_params,
        )
    }))
    .await?;

    let alice = RevmMiddleware::new(&environment, Some("alice"))?;
    markets[0]
        .0
        .mint(alice.address(), U256::exp10(24))
        .send()
        .await?
        .await?;
    MockERC20::new(markets[0].0.address(), alice.clone())
        .approve(markets[0].1.address(), U256::MAX)
        .send()
        .await?
        .await?;
    let alice_market = Market::new(markets[0].1.address(), alice.clone());
    alice_market
        .deposit(U256::exp10(20), alice.address())
        .send()
        .await?
        .await?;
    alice_market
        .borrow(U256::exp10(19), alice.address(), alice.address())
        .send()
        .await?
        .await?;

    for _ in 1..markets[0].2.trajectory.paths[0].len() {
        for (_, _, price_changer) in &mut markets {
            price_changer.update_price().await?;
        }
    }

    Ok(())
}

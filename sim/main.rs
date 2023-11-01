use std::process::Command;

use anyhow::{Ok, Result};
use arbiter_core::{
    data_collection::EventLogger,
    environment::builder::{BlockSettings, EnvironmentBuilder},
    middleware::RevmMiddleware,
};
use ethers::types::{Address, Bytes, U128, U256};
use futures::future::try_join_all;
use log::info;
use serde_json::from_slice;

use crate::{
    agents::{liquidator::Liquidator, price_changer::PriceProcessParameters},
    bindings::{
        auditor::{Auditor, LiquidationIncentive},
        erc1967_proxy::ERC1967Proxy,
        market::Market,
        mock_erc20::MockERC20,
        previewer::Previewer,
    },
    startup::{deploy_market, Finance},
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

    let finance = from_slice::<Finance>(
        &Command::new("npx")
            .arg("hardhat")
            .arg("--network")
            .arg("optimism")
            .arg("finance")
            .output()?
            .stdout,
    )?;

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
            liquidator: float_to_wad(finance.liquidation_incentive.liquidator).as_u128(),
            lenders: float_to_wad(finance.liquidation_incentive.lenders).as_u128(),
        })
        .send()
        .await?
        .await?;

    let mut markets = try_join_all(finance.markets.keys().map(|symbol| {
        let initial_price = match symbol.as_str() {
            "WETH" => 1850.0,
            "wstETH" => 2100.0,
            "OP" => 1.40,
            _ => 1.0,
        };
        deploy_market(
            symbol,
            match symbol.as_str() {
                "USDC" => 6,
                _ => 18,
            },
            auditor.clone(),
            finance.clone(),
            PriceProcessParameters {
                initial_price,
                mean: initial_price,
                std_dev: 0.01,
                theta: 3.0,
                t_0: 0.0,
                t_n: 100.0,
                n_steps: 2_500,
                seed: None,
            },
        )
    }))
    .await?;
    let mut listener = EventLogger::builder().directory("artifacts/simulator");
    for (_, market, _) in &markets {
        let name = market.symbol().call().await?;
        info!("{:9} {}", name, market.address());
        listener = listener.add(market.events(), name);
    }
    listener.run()?;

    let alice = RevmMiddleware::new(&environment, Some("alice"))?;
    markets[0]
        .0
        .mint(alice.address(), U256::exp10(18) * 1_000_000)
        .send()
        .await?
        .await?;
    MockERC20::new(markets[0].0.address(), alice.clone())
        .approve(markets[0].1.address(), U256::MAX)
        .send()
        .await?
        .await?;
    Market::new(markets[0].1.address(), alice.clone())
        .deposit(U256::exp10(18) * 1_000_000, alice.address())
        .send()
        .await?
        .await?;
    Auditor::new(auditor.address(), alice.clone())
        .enter_market(markets[0].1.address())
        .send()
        .await?
        .await?;
    markets[1]
        .0
        .mint(deployer.address(), U256::exp10(6) * 1_000_000)
        .send()
        .await?
        .await?;
    markets[1]
        .0
        .approve(markets[1].1.address(), U256::MAX)
        .send()
        .await?
        .await?;
    markets[1]
        .1
        .deposit(U256::exp10(6) * 1_000_000, deployer.address())
        .send()
        .await?
        .await?;
    Market::new(markets[1].1.address(), alice.clone())
        .borrow(U256::exp10(6) * 810_000, alice.address(), alice.address())
        .send()
        .await?
        .await?;

    let liquidator = Liquidator::new(
        auditor.clone(),
        Previewer::deploy(deployer.clone(), (auditor.address(), Address::zero()))?
            .send()
            .await?,
        [alice.address()],
    )
    .await?;
    for _ in 1..markets[0].2.trajectory.paths[0].len() {
        for (_, _, price_changer) in &mut markets {
            price_changer.update_price().await?;
        }
        liquidator.check_liquidations().await?;
    }
    environment.stop()?;

    Ok(())
}

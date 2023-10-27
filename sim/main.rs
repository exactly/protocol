use anyhow::{Ok, Result};
use arbiter_core::{environment::builder::EnvironmentBuilder, middleware::RevmMiddleware};
use ethers::types::{Bytes, I256, U128, U256};

use bindings::{
    auditor::{Auditor, LiquidationIncentive},
    erc1967_proxy::ERC1967Proxy,
    interest_rate_model::InterestRateModel,
    market::Market,
    mock_erc20::MockERC20,
    mock_price_feed::MockPriceFeed,
};

#[allow(unused_imports)]
mod bindings;

#[tokio::main]
pub async fn main() -> Result<()> {
    let environment = EnvironmentBuilder::new().build();
    let deployer = RevmMiddleware::new(&environment, None)?;

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

    let asset = MockERC20::deploy(
        deployer.clone(),
        ("DAI".to_string(), "DAI".to_string(), U256::from(18)),
    )?
    .send()
    .await?;

    let market = Market::new(
        ERC1967Proxy::deploy(
            deployer.clone(),
            (
                Market::deploy(deployer.clone(), (asset.address(), auditor.address()))?
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
    market
        .initialize(
            6,
            U128::exp10(18).as_u128() * 2,
            irm.address(),
            U256::exp10(16) * 2 / (24 * 3_600),
            U256::exp10(17),
            U128::exp10(17).as_u128(),
            U256::exp10(14) * 46,
            U256::exp10(16) * 42,
        )
        .send()
        .await?
        .await?;

    let price_feed = MockPriceFeed::deploy(deployer.clone(), (U256::from(18), I256::exp10(18)))?
        .send()
        .await?;
    auditor
        .enable_market(
            market.address(),
            price_feed.address(),
            U128::exp10(17).as_u128() * 9,
        )
        .send()
        .await?
        .await?;

    let alice = RevmMiddleware::new(&environment, None)?;
    asset
        .mint(alice.address(), U256::exp10(24))
        .send()
        .await?
        .await?;
    MockERC20::new(asset.address(), alice.clone())
        .approve(market.address(), U256::MAX)
        .send()
        .await?
        .await?;
    let alice_market = Market::new(market.address(), alice.clone());
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

    Ok(())
}

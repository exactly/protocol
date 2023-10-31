use std::sync::Arc;

use anyhow::{Ok, Result};
use arbiter_core::{math::float_to_wad, middleware::RevmMiddleware};
use ethers::types::{Bytes, I256, U128, U256};

use crate::{
    agents::price_changer::{PriceChanger, PriceProcessParameters},
    bindings::{
        auditor::Auditor, erc1967_proxy::ERC1967Proxy, interest_rate_model::InterestRateModel,
        market::Market, mock_erc20::MockERC20, mock_price_feed::MockPriceFeed,
    },
};

pub async fn deploy_market(
    symbol: &str,
    decimals: i32,
    deployer: Arc<RevmMiddleware>,
    auditor: Auditor<RevmMiddleware>,
    irm: InterestRateModel<RevmMiddleware>,
    price_process_params: PriceProcessParameters,
) -> Result<(
    MockERC20<RevmMiddleware>,
    Market<RevmMiddleware>,
    PriceChanger,
)> {
    let asset = MockERC20::deploy(
        deployer.clone(),
        (symbol.to_string(), symbol.to_string(), U256::from(decimals)),
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

    let price_feed = MockPriceFeed::deploy(
        deployer.clone(),
        (
            U256::from(18),
            I256::from_raw(float_to_wad(price_process_params.initial_price)),
        ),
    )?
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

    Ok((
        asset,
        market,
        PriceChanger::new(price_feed.clone(), price_process_params),
    ))
}

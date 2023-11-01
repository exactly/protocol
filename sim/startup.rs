use std::collections::HashMap;

use anyhow::{Ok, Result};
use arbiter_core::{math::float_to_wad, middleware::RevmMiddleware};
use ethers::types::{Bytes, I256, U128, U256};
use serde::{Deserialize, Serialize};

use crate::{
    agents::price_changer::{PriceChanger, PriceProcessParameters},
    bindings::{
        auditor::Auditor, erc1967_proxy::ERC1967Proxy, interest_rate_model::InterestRateModel,
        market::Market, mock_erc20::MockERC20, mock_price_feed::MockPriceFeed,
    },
};

pub async fn deploy_market(
    symbol: &str,
    decimals: u8,
    auditor: Auditor<RevmMiddleware>,
    finance: Finance,
    price_process_params: PriceProcessParameters,
) -> Result<(
    MockERC20<RevmMiddleware>,
    Market<RevmMiddleware>,
    PriceChanger,
)> {
    let market_params = finance.markets.get(symbol).unwrap();
    let deployer = auditor.client();
    let asset = MockERC20::deploy(
        deployer.clone(),
        (symbol.to_string(), symbol.to_string(), U256::from(decimals)),
    )?
    .send()
    .await?;

    let irm = InterestRateModel::deploy(
        deployer.clone(),
        (
            float_to_wad(market_params.fixed_curve.a),
            I256::from((market_params.fixed_curve.b * 1e18) as i128),
            float_to_wad(market_params.fixed_curve.max_utilization),
            float_to_wad(market_params.floating_curve.a),
            I256::from((market_params.floating_curve.b * 1e18) as i128),
            float_to_wad(market_params.floating_curve.max_utilization),
        ),
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
            finance.future_pools,
            float_to_wad(finance.earnings_accumulator_smooth_factor).as_u128(),
            irm.address(),
            float_to_wad(finance.penalty_rate_per_day) / (24 * 3_600),
            float_to_wad(finance.backup_fee_rate),
            float_to_wad(finance.reserve_factor).as_u128(),
            float_to_wad(finance.damp_speed.up),
            float_to_wad(finance.damp_speed.down),
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
        PriceChanger::new(symbol, price_feed.clone(), price_process_params),
    ))
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Finance {
    pub treasury_fee_rate: f64,
    pub liquidation_incentive: LiquidationIncentive,
    pub penalty_rate_per_day: f64,
    pub backup_fee_rate: f64,
    pub reserve_factor: f64,
    pub damp_speed: DampSpeed,
    pub future_pools: u8,
    pub earnings_accumulator_smooth_factor: f64,
    pub escrow: Escrow,
    pub rewards: DefaultRewards,
    pub markets: HashMap<String, MarketParameters>,
}

#[derive(Copy, Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiquidationIncentive {
    pub liquidator: f64,
    pub lenders: f64,
}

#[derive(Copy, Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DampSpeed {
    pub up: f64,
    pub down: f64,
}

#[derive(Copy, Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Escrow {
    pub vesting_period: f64,
    pub reserve_ratio: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DefaultRewards {
    pub undistributed_factor: f64,
    pub flip_speed: f64,
    pub compensation_factor: f64,
    pub transition_factor: f64,
    pub borrow_allocation_weight_factor: f64,
    pub deposit_allocation_weight_addend: f64,
    pub deposit_allocation_weight_factor: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketParameters {
    pub adjust_factor: f64,
    pub floating_curve: InterestRateModelParameters,
    pub fixed_curve: InterestRateModelParameters,
    pub rewards: HashMap<String, Rewards>,
}

#[derive(Copy, Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InterestRateModelParameters {
    pub a: f64,
    pub b: f64,
    pub max_utilization: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rewards {
    pub undistributed_factor: f64,
    pub flip_speed: f64,
    pub compensation_factor: f64,
    pub transition_factor: f64,
    pub borrow_allocation_weight_factor: f64,
    pub deposit_allocation_weight_addend: f64,
    pub deposit_allocation_weight_factor: f64,
    pub total: f64,
    pub debt: f64,
    pub start: String,
    pub period: f64,
}

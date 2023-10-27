use anyhow::{Ok, Result};
use arbiter_core::{environment::builder::EnvironmentBuilder, middleware::RevmMiddleware};
use ethers::types::{Bytes, U256};

use bindings::{
    auditor::{Auditor, LiquidationIncentive},
    erc1967_proxy::ERC1967Proxy,
};

#[allow(unused_imports)]
mod bindings;

#[tokio::main]
pub async fn main() -> Result<()> {
    let environment = EnvironmentBuilder::new().build();
    let client = RevmMiddleware::new(&environment, None)?;
    let auditor = Auditor::new(
        ERC1967Proxy::deploy(
            client.clone(),
            (
                Auditor::deploy(client.clone(), U256::from(18))?
                    .send()
                    .await?
                    .address(),
                Bytes::default(),
            ),
        )?
        .send()
        .await?
        .address(),
        client.clone(),
    );
    auditor
        .initialize(LiquidationIncentive {
            liquidator: 90_000_000_000_000_000,
            lenders: 10_000_000_000_000_000,
        })
        .send()
        .await?
        .await?;
    Ok(())
}

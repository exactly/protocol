use anyhow::{Ok, Result};
use arbiter_core::{
    math::{float_to_wad, OrnsteinUhlenbeck, StochasticProcess, Trajectories},
    middleware::RevmMiddleware,
};
use ethers::types::I256;
use log::info;
use serde::{Deserialize, Serialize};

use crate::bindings::mock_price_feed::MockPriceFeed;

pub struct PriceChanger {
    pub trajectory: Trajectories,
    pub price_feed: MockPriceFeed<RevmMiddleware>,
    pub index: usize,
}

impl PriceChanger {
    pub fn new(price_feed: MockPriceFeed<RevmMiddleware>, params: PriceProcessParameters) -> Self {
        let PriceProcessParameters {
            initial_price,
            mean,
            std_dev,
            theta,
            t_0,
            t_n,
            num_steps,
            seed,
        } = params;
        let process = OrnsteinUhlenbeck::new(mean, std_dev, theta);

        let trajectory = match seed {
            Some(seed) => {
                process.seedable_euler_maruyama(initial_price, t_0, t_n, num_steps, 1, false, seed)
            }
            None => process.euler_maruyama(initial_price, t_0, t_n, num_steps, 1, false),
        };

        Self {
            trajectory,
            price_feed,
            index: 1,
        }
    }

    pub async fn update_price(&mut self) -> Result<()> {
        let price = self.trajectory.paths[0][self.index];
        info!("updating price to: {}", price);
        self.price_feed
            .set_price(I256::from_raw(float_to_wad(price)))
            .send()
            .await?
            .await?;
        self.index += 1;
        Ok(())
    }
}

#[derive(Copy, Clone, Debug, Serialize, Deserialize)]
pub struct PriceProcessParameters {
    pub initial_price: f64,
    pub mean: f64,
    pub std_dev: f64,
    pub theta: f64,
    pub t_0: f64,
    pub t_n: f64,
    pub num_steps: usize,
    pub seed: Option<u64>,
}

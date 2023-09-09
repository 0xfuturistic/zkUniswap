#![no_main]

use ethers_core::types::{I256, U256};
use risc0_zkvm::guest::env;
use uniswap_v3_math::swap_math::compute_swap_step;

risc0_zkvm::guest::entry!(main);

pub fn main() {
    let price = env::read();
    let price_target = env::read();
    let liquidity = 2e18 as u128;
    let amount = env::read();
    let fee = 600;

    let (sqrt_p, amount_in, amount_out, fee_amount) =
        compute_swap_step(price, price_target, liquidity, amount, fee).unwrap();

    env::commit(&amount_out);
}

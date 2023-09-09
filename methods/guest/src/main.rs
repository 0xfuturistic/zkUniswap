#![no_main]


use risc0_zkvm::guest::env;
use uniswap_v3_math::{swap_math::compute_swap_step, sqrt_price_math::{get_next_sqrt_price_from_input, get_next_sqrt_price_from_output}};
use ethers_core::types::{I256, U256};

risc0_zkvm::guest::entry!(main);

pub fn main() {
    let price = U256::from_dec_str("79228162514264337593543950336").unwrap();
    let price_target = U256::from_dec_str("79623317895830914510639640423").unwrap();
    let liquidity = 2e18 as u128;
    let amount = I256::from_dec_str("1000000000000000000").unwrap();
    let fee = 600;
    let zero_for_one = false;

    let (sqrt_p, amount_in, amount_out, fee_amount) =
        compute_swap_step(price, price_target, liquidity, amount, fee).unwrap();
}

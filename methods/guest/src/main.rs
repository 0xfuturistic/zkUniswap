#![no_main]

use risc0_zkvm::guest::env;
use uniswap_v3_math::swap_math::compute_swap_step;

risc0_zkvm::guest::entry!(main);

pub fn main() {
    let price = env::read();
    let price_target = env::read();
    let liquidity = env::read::<String>().parse::<u128>().unwrap();
    let amount = env::read();
    let fee = env::read();

    let (sqrt_p, amount_in, amount_out, fee_amount) =
        compute_swap_step(price, price_target, liquidity, amount, fee).unwrap();

    env::commit(&amount_out);
}

#![no_main]

use std::io::Read;

use ethabi::{ethereum_types::U256, ParamType, Token};
use risc0_zkvm::guest::env;
use uniswap_v3_math::swap_math::compute_swap_step;

risc0_zkvm::guest::entry!(main);

fn main() {
    // Read data sent from the application contract.
    let mut input_bytes = Vec::<u8>::new();
    env::stdin().read_to_end(&mut input_bytes).unwrap();
    // Type array passed to `ethabi::decode_whole` should match the types encoded in
    // the application contract.
    let input = ethabi::decode_whole(
        &[
            ParamType::Uint(160), // price
            ParamType::Uint(160), // price_target
            ParamType::Uint(128), // liquidity
            ParamType::Uint(256), // amount
            ParamType::Uint(24),  // fee
        ],
        &input_bytes,
    )
    .unwrap();

    let price: U256 = input[0].clone().into_uint().unwrap();
    let price_target: U256 = input[1].clone().into_uint().unwrap();
    let liquidity: u128 = input[2].clone().into_uint().unwrap().as_u128();
    let amount = ethers_core::types::I256::from_raw(input[3].clone().into_uint().unwrap());
    let fee: u32 = input[4].clone().into_uint().unwrap().as_u32();

    let (sqrt_p, amount_in, amount_out, fee_amount) =
        compute_swap_step(price, price_target, liquidity, amount, fee).unwrap();

    println!(
        "hey! {} {} {} {}",
        sqrt_p, amount_in, amount_out, fee_amount
    );

    // Commit the journal that will be received by the application contract.
    // Encoded types should match the args expected by the application callback.
    env::commit_slice(&ethabi::encode(&[
        Token::Uint(sqrt_p),
        Token::Uint(amount_in),
        Token::Uint(amount_out),
        Token::Uint(fee_amount),
    ]));
}

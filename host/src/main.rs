// TODO: Update the name of the method loaded by the prover. E.g., if the method
// is `multiply`, replace `METHOD_NAME_ELF` with `MULTIPLY_ELF` and replace
// `METHOD_NAME_ID` with `MULTIPLY_ID`
use ethers_core::types::{I256, U256};
use methods::{METHOD_NAME_ELF, METHOD_NAME_ID};
use risc0_zkvm::{
    default_prover,
    serde::{from_slice, to_vec},
    ExecutorEnv, Receipt,
};
use std::str::FromStr;

fn main() {
    let price = U256::from_dec_str("79228162514264337593543950336").unwrap();
    let price_target = U256::from_dec_str("79623317895830914510639640423").unwrap();
    // we represent liquidity val as a string because we can't serialize it as u128 type
    let liquidity = "2000000000000000000";
    let amount = I256::from_dec_str("1000000000000000000").unwrap();
    let fee = 600;

    let env = ExecutorEnv::builder()
        // Send a & b to the guest
        .add_input(&to_vec(&price).unwrap())
        .add_input(&to_vec(&price_target).unwrap())
        .add_input(&to_vec(&liquidity).unwrap())
        .add_input(&to_vec(&amount).unwrap())
        .add_input(&to_vec(&fee).unwrap())
        .build()
        .unwrap();

    // Obtain the default prover.
    let prover = default_prover();

    // Produce a receipt by proving the specified ELF binary.
    let receipt = prover.prove_elf(env, METHOD_NAME_ELF).unwrap();

    // TODO: Implement code for transmitting or serializing the receipt for
    // other parties to verify here

    // Optional: Verify receipt to confirm that recipients will also be able to
    // verify your receipt
    receipt.verify(METHOD_NAME_ID).unwrap();

    // Extract journal of receipt (i.e. output c, where c = a * b)
    let c: U256 = from_slice(&receipt.journal).expect(
        "Journal output should deserialize into the same types (& order) that it was written",
    );

    // Report the product
    println!("The amount out is {}, and I can prove it!", c);
}

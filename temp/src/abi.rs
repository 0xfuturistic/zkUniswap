#[cfg(feature = "ethers_contract")]
pub mod ethers {
    use ethers_contract::abigen;

    abigen!(
        IUniswapV3Pool,
        r#"[
            function tickBitmap(int16) external returns (uint256)
        ]"#;
    );
}
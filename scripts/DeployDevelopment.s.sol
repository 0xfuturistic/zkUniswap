// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import "../contracts/interfaces/IUniswapV3Manager.sol";
import "../contracts/lib/FixedPoint96.sol";
import "../contracts/lib/Math.sol";
import "../contracts/UniswapV3Factory.sol";
import "../contracts/UniswapV3Manager.sol";
import "../contracts/UniswapV3Pool.sol";
import "../contracts/UniswapV3Quoter.sol";
import "../tests/ERC20Mintable.sol";
import "../tests/TestUtils.sol";

import {IBonsaiRelay} from "bonsai/IBonsaiRelay.sol";
import {BonsaiCheats} from "bonsai/BonsaiCheats.sol";

import {BonsaiDeploy} from "./BonsaiDeploy.sol";
import {BonsaiStarter} from "../contracts/BonsaiStarter.sol";

contract DeployDevelopment is Script, TestUtils, BonsaiCheats, BonsaiDeploy {
    struct TokenBalances {
        uint256 uni;
        uint256 usdc;
        uint256 usdt;
        uint256 wbtc;
        uint256 weth;
    }

    TokenBalances balances =
        TokenBalances({uni: 200 ether, usdc: 2_000_000 ether, usdt: 2_000_000 ether, wbtc: 20 ether, weth: 100 ether});

    function run() public {
        // DEPLOYING STARGED
        vm.startBroadcast();

        ERC20Mintable weth = new ERC20Mintable("Wrapped Ether", "WETH", 18);
        ERC20Mintable usdc = new ERC20Mintable("USD Coin", "USDC", 18);
        ERC20Mintable uni = new ERC20Mintable("Uniswap Coin", "UNI", 18);
        ERC20Mintable wbtc = new ERC20Mintable("Wrapped Bitcoin", "WBTC", 18);
        ERC20Mintable usdt = new ERC20Mintable("USD Token", "USDT", 18);

        UniswapV3Factory factory = new UniswapV3Factory();
        UniswapV3Manager manager = new UniswapV3Manager(address(factory));
        UniswapV3Quoter quoter = new UniswapV3Quoter(address(factory));

        IBonsaiRelay bonsaiRelay = deployBonsaiRelay();
        relayAddress = address(bonsaiRelay);
        uploadImages();

        swapImageId = queryImageId("SWAP");
        console.log("Image ID for SWAP is ", vm.toString(swapImageId));

        UniswapV3Pool wethUsdc = deployPool(factory, address(weth), address(usdc), 3000, 5000);

        UniswapV3Pool wethUni = deployPool(factory, address(weth), address(uni), 3000, 10);

        UniswapV3Pool wbtcUSDT = deployPool(factory, address(wbtc), address(usdt), 3000, 20_000);

        UniswapV3Pool usdtUSDC = deployPool(factory, address(usdt), address(usdc), 500, 1);

        uni.mint(msg.sender, balances.uni);
        usdc.mint(msg.sender, balances.usdc);
        usdt.mint(msg.sender, balances.usdt);
        wbtc.mint(msg.sender, balances.wbtc);
        weth.mint(msg.sender, balances.weth);

        uni.approve(address(manager), 100 ether);
        usdc.approve(address(manager), 1_005_000 ether);
        usdt.approve(address(manager), 1_200_000 ether);
        wbtc.approve(address(manager), 10 ether);
        weth.approve(address(manager), 11 ether);

        manager.mint(mintParams(address(weth), address(usdc), 4545, 5500, 1 ether, 5000 ether));
        manager.mint(mintParams(address(weth), address(uni), 7, 13, 10 ether, 100 ether));

        manager.mint(mintParams(address(wbtc), address(usdt), 19400, 20500, 10 ether, 200_000 ether));
        manager.mint(
            mintParams(
                address(usdt),
                address(usdc),
                uint160(77222060634363714391462903808), //  0.95, int(math.sqrt(0.95) * 2**96)
                uint160(81286379615119694729911992320), // ~1.05, int(math.sqrt(1/0.95) * 2**96)
                1_000_000 ether,
                1_000_000 ether,
                500
            )
        );

        vm.stopBroadcast();
        // DEPLOYING DONE

        console.log("WETH address", address(weth));
        console.log("UNI address", address(uni));
        console.log("USDC address", address(usdc));
        console.log("USDT address", address(usdt));
        console.log("WBTC address", address(wbtc));

        console.log("Factory address", address(factory));
        console.log("Manager address", address(manager));
        console.log("Quoter address", address(quoter));

        console.log("USDT/USDC address", address(usdtUSDC));
        console.log("WBTC/USDT address", address(wbtcUSDT));
        console.log("WETH/UNI address", address(wethUni));
        console.log("WETH/USDC address", address(wethUsdc));
    }
}

.PHONY: test

deploy:
	RISC0_DEV_MODE=false forge script scripts/DeployDevelopment.s.sol --broadcast --fork-url $$ETH_RPC_URL --private-key $$PRIVATE_KEY

deploy-dev:
	RISC0_DEV_MODE=true forge script scripts/DeployDevelopment.s.sol --broadcast --fork-url $$ETH_RPC_URL --private-key $$PRIVATE_KEY

update-abis:
	forge inspect UniswapV3Factory abi > ui/src/abi/Factory.json
	forge inspect UniswapV3Manager abi > ui/src/abi/Manager.json
	forge inspect UniswapV3Pool abi > ui/src/abi/Pool.json
	forge inspect UniswapV3Quoter abi > ui/src/abi/Quoter.json

test:
	forge test --ffi
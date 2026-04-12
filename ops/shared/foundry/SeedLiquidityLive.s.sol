// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

contract SeedLiquidityLive is Script {
    uint256 constant MINT_POSITION = 0x02;
    uint256 constant CLOSE_CURRENCY = 0x12;
    uint256 constant SWEEP = 0x14;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function run() external {
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2Addr = vm.envAddress("PERMIT2");
        address stable = vm.envAddress("DEPLOY_STABLE");
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        int24 tickSpacing = int24(int256(vm.envUint("DEPLOY_TICK_SPACING")));
        int24 tickLower = int24(int256(vm.envInt("SEED_TICK_LOWER")));
        int24 tickUpper = int24(int256(vm.envInt("SEED_TICK_UPPER")));
        uint256 liquidity = vm.envUint("SEED_LIQUIDITY");
        uint128 amount0Max = uint128(vm.envUint("SEED_AMOUNT0_MAX"));
        uint128 amount1Max = uint128(vm.envUint("SEED_AMOUNT1_MAX"));

        PoolKey memory key = PoolKey({
            currency0: address(0),
            currency1: stable,
            fee: 8388608,
            tickSpacing: tickSpacing,
            hooks: hookAddr
        });

        // Actions: MINT_POSITION, CLOSE_CURRENCY(ETH), CLOSE_CURRENCY(USDC), SWEEP(ETH)
        bytes memory actions = new bytes(4);
        actions[0] = bytes1(uint8(MINT_POSITION));
        actions[1] = bytes1(uint8(CLOSE_CURRENCY));
        actions[2] = bytes1(uint8(CLOSE_CURRENCY));
        actions[3] = bytes1(uint8(SWEEP));

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address recipient = vm.addr(pk);

        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, bytes(""));
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        params[3] = abi.encode(key.currency0, recipient);

        bytes memory unlockData = abi.encode(actions, params);
        uint256 deadline = block.timestamp + 300;

        console.log("[seed] recipient:", recipient);
        console.log("[seed] tickLower:", tickLower);
        console.log("[seed] tickUpper:", tickUpper);
        console.log("[seed] liquidity:", liquidity);
        console.log("[seed] amount0Max (ETH wei):", amount0Max);
        console.log("[seed] amount1Max (USDC raw):", amount1Max);

        vm.startBroadcast(pk);

        IERC20(stable).approve(permit2Addr, type(uint256).max);
        IPermit2(permit2Addr).approve(stable, positionManager, type(uint160).max, type(uint48).max);

        IPositionManager(positionManager).modifyLiquidities{value: uint256(amount0Max)}(unlockData, deadline);

        vm.stopBroadcast();

        console.log("[seed] ok: position minted");
    }
}

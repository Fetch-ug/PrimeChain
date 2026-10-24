// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";

/**
 * @notice Deploys the emission distributor with the approved D4 parameters and asserts
 *         them immediately after deployment.
 *
 * @dev The assertions are the point of this script. `allocation()` is immutable and the
 *      constructor only bounds it by EMISSIONS_CEILING, so a deployment with a wrong
 *      allocation would be permanent and silent. The script fails loudly instead:
 *
 *        allocation == 1e9            (D4 total emissions ceiling)
 *        EMISSIONS_CEILING == 1e9     (the constant promise)
 *        maxPerEpoch == 500,000       (D4 launch rate)
 *        maxPerAccountPerEpoch == 200 (D4 per-account rate)
 *
 *      This file is executed by the `deploy + RPC smoke` CI job on anvil, so the
 *      assertions run on every push, not only at mainnet deploy time.
 *
 * Usage:
 *   PRIME_ADDRESS=0x... \
 *   DISTRIBUTOR_ADMIN=0x... DISTRIBUTOR_SEALER=0x... \
 *   DISTRIBUTOR_CONFIG=0x... DISTRIBUTOR_PAUSER=0x... \
 *   forge script script/DeployRewardDistributor.s.sol:DeployRewardDistributor \
 *     --rpc-url $PRIME_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast
 */
contract DeployRewardDistributor is Script {
    uint256 internal constant EXPECTED_ALLOCATION = 1_000_000_000e18;
    uint256 internal constant INITIAL_MAX_PER_EPOCH = 500_000e18;
    uint256 internal constant INITIAL_MAX_PER_ACCOUNT = 200e18;

    function run() external returns (RewardDistributor distributor) {
        address primeAddress = vm.envAddress("PRIME_ADDRESS");
        address admin = vm.envAddress("DISTRIBUTOR_ADMIN");
        address sealer = vm.envAddress("DISTRIBUTOR_SEALER");
        address configAdmin = vm.envAddress("DISTRIBUTOR_CONFIG");
        address pauser = vm.envAddress("DISTRIBUTOR_PAUSER");

        vm.startBroadcast();
        distributor = new RewardDistributor(
            IERC20(primeAddress),
            EXPECTED_ALLOCATION,
            admin,
            sealer,
            configAdmin,
            pauser,
            INITIAL_MAX_PER_EPOCH,
            INITIAL_MAX_PER_ACCOUNT
        );
        vm.stopBroadcast();

        // --- post-deploy assertions: these are the deployment's own tests -----------
        require(distributor.allocation() == EXPECTED_ALLOCATION, "allocation != 1,000,000,000e18");
        require(distributor.EMISSIONS_CEILING() == EXPECTED_ALLOCATION, "ceiling != 1,000,000,000e18");
        require(distributor.MAX_EPOCH_CAP() >= INITIAL_MAX_PER_EPOCH, "epoch cap above MAX_EPOCH_CAP");
        require(distributor.maxPerEpoch() == INITIAL_MAX_PER_EPOCH, "unexpected maxPerEpoch");
        require(distributor.maxPerAccountPerEpoch() == INITIAL_MAX_PER_ACCOUNT, "unexpected maxPerAccount");
        require(distributor.totalReleased() == 0, "distributor must start unreleased");

        console2.log("RewardDistributor :", address(distributor));
        console2.log("Prime             :", primeAddress);
        console2.log("Allocation        :", distributor.allocation());
        console2.log("Max per epoch     :", distributor.maxPerEpoch());
        console2.log("Max per account   :", distributor.maxPerAccountPerEpoch());
    }
}

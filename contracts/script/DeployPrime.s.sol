// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Prime} from "../src/Prime.sol";

/**
 * @notice Deploys Prime with the entire supply minted to an existing treasury.
 *
 * Usage (the treasury must already exist — a Safe or the Timelock, never an EOA
 * in production):
 *
 *   PRIME_TREASURY=0x... \
 *   forge script script/DeployPrime.s.sol:DeployPrime \
 *     --rpc-url $PRIME_RPC_URL \
 *     --private-key $DEPLOYER_PRIVATE_KEY \
 *     --broadcast
 *
 * The deployer key is a throwaway deployment key. It receives nothing: the
 * constructor mints to `PRIME_TREASURY`, not to `msg.sender`. That is deliberate
 * so a compromised deployer key cannot redirect genesis supply.
 */
contract DeployPrime is Script {
    /// @notice Expected genesis supply, written independently of the contract.
    /// @dev Deliberately a literal rather than `Prime.TOTAL_SUPPLY`:
    ///      1. a `public constant` is NOT reachable through the contract type in
    ///         Solidity (that is a compile error, which is what this fixes), and
    ///      2. even the instance getter would be self-referential — asking the
    ///         contract to confirm its own constant proves nothing. A literal
    ///         fails the deploy if the contract's supply ever changes.
    uint256 internal constant EXPECTED_SUPPLY = 2_000_000_000e18;

    function run() external returns (Prime prime) {
        address treasury = vm.envAddress("PRIME_TREASURY");
        require(treasury != address(0), "PRIME_TREASURY not set");

        vm.startBroadcast();
        prime = new Prime(treasury);
        vm.stopBroadcast();

        require(prime.totalSupply() == EXPECTED_SUPPLY, "supply invariant broken on deploy");
        require(prime.balanceOf(treasury) == EXPECTED_SUPPLY, "treasury did not receive supply");

        console2.log("Prime deployed at :", address(prime));
        console2.log("Treasury          :", treasury);
        console2.log("Decimals          :", uint256(prime.decimals()));
        console2.log("Total supply      :", prime.totalSupply());
    }
}

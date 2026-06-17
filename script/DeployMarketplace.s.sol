// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentMarketplace.sol";

/// @notice Deploys AgentMarketplace.sol behind a UUPS proxy.
///         env: DEPLOYER_PRIVATE_KEY (required)
///              MARKETPLACE_ADMIN     (required) — proxy admin / fee setter
///              MARKETPLACE_FEE_RECIPIENT (required) — receives protocolFee
///              MARKETPLACE_FEE_BPS (default 250 = 2.5%)
contract DeployMarketplace is Script {
    function run() public {
        uint256 pk     = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin  = vm.envAddress("MARKETPLACE_ADMIN");
        address feeRcv = vm.envAddress("MARKETPLACE_FEE_RECIPIENT");
        uint256 feeBps = vm.envOr("MARKETPLACE_FEE_BPS", uint256(250));

        vm.startBroadcast(pk);

        AgentMarketplace impl = new AgentMarketplace();
        console.log("AgentMarketplace impl:", address(impl));

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentMarketplace.initialize, (admin, feeRcv, feeBps))
        );
        console.log("AgentMarketplace proxy:", address(proxy));
        console.log("  admin:        ", admin);
        console.log("  feeRecipient: ", feeRcv);
        console.log("  protocolFeeBps:", feeBps);

        vm.stopBroadcast();
    }
}

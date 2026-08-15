// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {IContinuousClearingAuction} from "cca/interfaces/IContinuousClearingAuction.sol";

// ponytail: compilation IS the check — proves the remappings resolve v4 + CCA.
contract DepsTest is Test {
    function test_remappingsResolve() public pure {
        assert(IPoolManager.unlock.selector != bytes4(0));
        assert(IHooks.beforeSwap.selector != bytes4(0));
        assert(IContinuousClearingAuction.exitBid.selector != bytes4(0));
    }
}

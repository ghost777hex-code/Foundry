// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {PriceManipulationExploit} from "../../src/PriceManipulationExploit.sol";
import {Test} from "forge-std/Test.sol";

contract PriceManipulationTest is Test {
    // address constant POOL = 0xE8c2030686fC3b0161Ee1def0E8d01dFe4FAc0Ac;
    // address constant VAULT1 = 0x85CBeD523459b7f6F81C11e710DF969703a8A70C;
    // address constant VAULT2 = 0xc86B1e7FA86834CaC1468937cdd53ba3cCbC1153;
    // address constant PROXY1 = 0x3803729416AA5207FE801C1C565B906F6f3f8a28;
    // address constant PROXY2 = 0x7CF8431E086e1bcdC9524fd305f7D5d8622CD75f;
    // address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 internal constant EXPLOIT_BLOCK = 25_874_402;

    PriceManipulationExploit internal exploit;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_ARCHIVE_RPC"), EXPLOIT_BLOCK - 1);

        exploit = new PriceManipulationExploit();
    }

    function test_Manipulation() public {
        uint256 profit = exploit.attack();

        emit log_named_uint("PROFIT WETH (after repaying both loans)", profit);
        assertGt(profit, 0, "exploit did not net a profit");
    }
}

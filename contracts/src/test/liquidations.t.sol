pragma solidity ^0.8.18;

import "./TestContracts/DevTestSetup.sol";

contract LiquidationsTest is DevTestSetup {
    function testLiquidationOffsetWithSurplus() public {
        uint256 liquidationAmount = 2000e18;
        uint256 collAmount = 2e18;

        priceFeed.setPrice(2000e18);
        vm.startPrank(A);
        uint256 ATroveId = borrowerOperations.openTrove(A, 0, collAmount, liquidationAmount, 0, 0, 0, 0);
        vm.stopPrank();

        vm.startPrank(B);
        borrowerOperations.openTrove(B, 0, 2 * collAmount, liquidationAmount, 0, 0, 0, 0);
        vm.stopPrank();
        // B deposits to SP
        makeSPDepositAndClaim(B, liquidationAmount);

        // Price drops
        priceFeed.setPrice(1100e18 - 1);
        uint256 price = priceFeed.fetchPrice();

        uint256 initialSPBoldBalance = stabilityPool.getTotalBoldDeposits();
        uint256 initialSPCollBalance = stabilityPool.getCollBalance();
        uint256 AInitialCollBalance = collToken.balanceOf(A);

        // Check not RM
        assertEq(troveManager.checkBelowCriticalThreshold(price), false, "System should not be below CT");

        // Check CR_A < MCR and TCR > CCR
        assertLt(troveManager.getCurrentICR(ATroveId, price), MCR);
        assertGt(troveManager.getTCR(price), CCR);

        uint256 trovesCount = troveManager.getTroveIdsCount();
        assertEq(trovesCount, 2);

        troveManager.liquidate(ATroveId);

        // Check Troves count reduced by 1
        trovesCount = troveManager.getTroveIdsCount();
        assertEq(trovesCount, 1);

        // Check SP Bold has decreased
        uint256 finalSPBoldBalance = stabilityPool.getTotalBoldDeposits();
        assertEq(initialSPBoldBalance - finalSPBoldBalance, liquidationAmount, "SP Bold balance mismatch");
        // Check SP Coll has  increased
        uint256 finalSPCollBalance = stabilityPool.getCollBalance();
        // liquidationAmount to Coll + 5%
        assertApproxEqAbs(
            finalSPCollBalance - initialSPCollBalance,
            liquidationAmount * DECIMAL_PRECISION / price * 105 / 100,
            10,
            "SP Coll balance mismatch"
        );

        // Check A retains ~4.5% of the collateral (after claiming from CollSurplus)
        // collAmount - 0.5% - (liquidationAmount to Coll + 5%)
        uint256 collSurplusAmount = collAmount * 995 / 1000 - liquidationAmount * DECIMAL_PRECISION / price * 105 / 100;
        assertEq(
            collToken.balanceOf(address(collSurplusPool)),
            collSurplusAmount,
            "CollSurplusPoll should have received collateral"
        );
        vm.startPrank(A);
        borrowerOperations.claimCollateral();
        vm.stopPrank();
        assertEq(collToken.balanceOf(A) - AInitialCollBalance, collSurplusAmount, "A collateral balance mismatch");
    }

    function testLiquidationOffsetNoSurplus() public {
        uint256 liquidationAmount = 10000e18;
        uint256 collAmount = 10e18;

        priceFeed.setPrice(2000e18);
        vm.startPrank(A);
        uint256 ATroveId = borrowerOperations.openTrove(A, 0, collAmount, liquidationAmount, 0, 0, 0, 0);
        vm.stopPrank();

        vm.startPrank(B);
        borrowerOperations.openTrove(B, 0, 3 * collAmount, liquidationAmount, 0, 0, 0, 0);
        vm.stopPrank();
        // B deposits to SP
        makeSPDepositAndClaim(B, liquidationAmount);

        // Price drops
        priceFeed.setPrice(1030e18);
        uint256 price = priceFeed.fetchPrice();

        uint256 initialSPBoldBalance = stabilityPool.getTotalBoldDeposits();
        uint256 initialSPCollBalance = stabilityPool.getCollBalance();

        // Check not RM
        assertEq(troveManager.checkBelowCriticalThreshold(price), false, "System should not be below CT");

        // Check CR_A < MCR and TCR > CCR
        assertLt(troveManager.getCurrentICR(ATroveId, price), MCR, "ICR too high");
        assertGe(troveManager.getTCR(price), CCR, "TCR too low");

        uint256 trovesCount = troveManager.getTroveIdsCount();
        assertEq(trovesCount, 2);

        troveManager.liquidate(ATroveId);

        // Check Troves count reduced by 1
        trovesCount = troveManager.getTroveIdsCount();
        assertEq(trovesCount, 1);

        // Check SP Bold has decreased
        uint256 finalSPBoldBalance = stabilityPool.getTotalBoldDeposits();
        assertEq(initialSPBoldBalance - finalSPBoldBalance, liquidationAmount, "SP Bold balance mismatch");
        // Check SP Coll has increased by coll minus coll gas comp
        uint256 finalSPCollBalance = stabilityPool.getCollBalance();
        // liquidationAmount to Coll + 5%
        assertApproxEqAbs(
            finalSPCollBalance - initialSPCollBalance, collAmount * 995 / 1000, 10, "SP Coll balance mismatch"
        );

        // Check there’s no surplus
        assertEq(collToken.balanceOf(address(collSurplusPool)), 0, "CollSurplusPoll should be empty");

        vm.startPrank(A);
        vm.expectRevert("CollSurplusPool: No collateral available to claim");
        borrowerOperations.claimCollateral();
        vm.stopPrank();
    }

    function testLiquidationRedistributionNoSurplus() public {
        uint256 liquidationAmount = 2000e18;
        uint256 collAmount = 2e18;

        priceFeed.setPrice(2000e18);
        vm.startPrank(A);
        uint256 ATroveId = borrowerOperations.openTrove(A, 0, collAmount, liquidationAmount, 0, 0, 0, 0);
        vm.stopPrank();

        vm.startPrank(B);
        uint256 BTroveId = borrowerOperations.openTrove(B, 0, 2 * collAmount, liquidationAmount, 0, 0, 0, 0);

        // Price drops
        priceFeed.setPrice(1100e18 - 1);
        uint256 price = priceFeed.fetchPrice();

        uint256 BInitialDebt = troveManager.getTroveEntireDebt(BTroveId);
        uint256 BInitialColl = troveManager.getTroveEntireColl(BTroveId);

        // Check not RM
        assertEq(troveManager.checkBelowCriticalThreshold(price), false, "System should not be below CT");

        // Check CR_A < MCR and TCR > CCR
        assertLt(troveManager.getCurrentICR(ATroveId, price), MCR);
        assertGt(troveManager.getTCR(price), CCR);

        // Check empty SP
        assertEq(stabilityPool.getTotalBoldDeposits(), 0, "SP should be empty");

        uint256 trovesCount = troveManager.getTroveIdsCount();
        assertEq(trovesCount, 2);

        troveManager.liquidate(ATroveId);

        // Check Troves count reduced by 1
        trovesCount = troveManager.getTroveIdsCount();
        assertEq(trovesCount, 1);

        // Check SP stays the same
        assertEq(stabilityPool.getTotalBoldDeposits(), 0, "SP should be empty");
        assertEq(stabilityPool.getCollBalance(), 0, "SP should not have Coll rewards");

        // Check B has received debt
        assertEq(troveManager.getTroveEntireDebt(BTroveId) - BInitialDebt, liquidationAmount, "B debt mismatch");
        // Check B has received all coll minus coll gas comp
        assertApproxEqAbs(
            troveManager.getTroveEntireColl(BTroveId) - BInitialColl,
            collAmount * 995 / 1000, // Collateral - coll gas comp
            10,
            "B trove coll mismatch"
        );

        assertEq(collToken.balanceOf(address(collSurplusPool)), 0, "CollSurplusPoll should be empty");
    }

    struct InitialValues {
        uint256 spBoldBalance;
        uint256 spCollBalance;
        uint256 ACollBalance;
        uint256 BDebt;
        uint256 BColl;
    }

    // Offset and Redistribution
    function testLiquidationMix() public {
        uint256 liquidationAmount = 2000e18;
        uint256 collAmount = 2e18;

        priceFeed.setPrice(2000e18);
        vm.startPrank(A);
        uint256 ATroveId = borrowerOperations.openTrove(A, 0, collAmount, liquidationAmount, 0, 0, 0, 0);
        vm.stopPrank();

        vm.startPrank(B);
        uint256 BTroveId = borrowerOperations.openTrove(B, 0, 2 * collAmount, liquidationAmount, 0, 0, 0, 0);
        vm.stopPrank();
        // B deposits to SP
        makeSPDepositAndClaim(B, liquidationAmount / 2);

        // Price drops
        priceFeed.setPrice(1100e18 - 1);
        uint256 price = priceFeed.fetchPrice();

        InitialValues memory initialValues;
        initialValues.spBoldBalance = stabilityPool.getTotalBoldDeposits();
        initialValues.spCollBalance = stabilityPool.getCollBalance();
        initialValues.ACollBalance = collToken.balanceOf(A);
        initialValues.BDebt = troveManager.getTroveEntireDebt(BTroveId);
        initialValues.BColl = troveManager.getTroveEntireColl(BTroveId);

        // Check not RM
        assertEq(troveManager.checkBelowCriticalThreshold(price), false, "System should not be below CT");

        // Check CR_A < MCR and TCR > CCR
        assertLt(troveManager.getCurrentICR(ATroveId, price), MCR);
        assertGt(troveManager.getTCR(price), CCR);

        uint256 trovesCount = troveManager.getTroveIdsCount();
        assertEq(trovesCount, 2);

        troveManager.liquidate(ATroveId);

        // Check Troves count reduced by 1
        trovesCount = troveManager.getTroveIdsCount();
        assertEq(trovesCount, 1);

        // Check SP Bold has decreased
        uint256 finalSPBoldBalance = stabilityPool.getTotalBoldDeposits();
        assertEq(initialValues.spBoldBalance - finalSPBoldBalance, liquidationAmount / 2, "SP Bold balance mismatch");
        // Check SP Coll has  increased
        uint256 finalSPCollBalance = stabilityPool.getCollBalance();
        // liquidationAmount to Coll + 5%
        assertApproxEqAbs(
            finalSPCollBalance - initialValues.spCollBalance,
            liquidationAmount / 2 * DECIMAL_PRECISION / price * 105 / 100,
            10,
            "SP Coll balance mismatch"
        );

        // Check B has received debt
        assertEq(
            troveManager.getTroveEntireDebt(BTroveId) - initialValues.BDebt, liquidationAmount / 2, "B debt mismatch"
        );
        // Check B has received coll
        assertApproxEqAbs(
            troveManager.getTroveEntireColl(BTroveId) - initialValues.BColl,
            //collAmount * 995 / 1000 - liquidationAmount / 2 * DECIMAL_PRECISION / price * 105 / 100,
            liquidationAmount / 2 * DECIMAL_PRECISION / price * 110 / 100,
            10,
            "B trove coll mismatch"
        );

        // Check A retains ~4.5% of the collateral (after claiming from CollSurplus)
        // collAmount - 0.5% - (liquidationAmount to Coll + 5%)
        uint256 collSurplusAmount = collAmount * 995 / 1000
            - liquidationAmount / 2 * DECIMAL_PRECISION / price * 105 / 100
            - liquidationAmount / 2 * DECIMAL_PRECISION / price * 110 / 100;
        assertApproxEqAbs(
            collToken.balanceOf(address(collSurplusPool)),
            collSurplusAmount,
            10,
            "CollSurplusPoll should have received collateral"
        );
        vm.startPrank(A);
        borrowerOperations.claimCollateral();
        vm.stopPrank();
        assertApproxEqAbs(
            collToken.balanceOf(A) - initialValues.ACollBalance, collSurplusAmount, 10, "A collateral balance mismatch"
        );
    }
}

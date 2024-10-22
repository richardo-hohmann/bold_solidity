// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "../Interfaces/IBorrowerOperations.sol";
import "../Interfaces/IWETH.sol";
import "./WETHZapper.sol";
import "../Dependencies/AddRemoveManagers.sol";
import "../Dependencies/Constants.sol";
import "./Interfaces/ILeverageZapper.sol";

// TODO: unwrap WETH in _returnLeftovers

contract LeverageWETHZapper is WETHZapper, ILeverageZapper {
    IPriceFeed public immutable priceFeed;

    constructor(IAddressesRegistry _addressesRegistry, IFlashLoanProvider _flashLoanProvider, IExchange _exchange)
        WETHZapper(_addressesRegistry, _flashLoanProvider, _exchange)
    {
        // Cache contracts
        IBorrowerOperations _borrowerOperations = borrowerOperations;

        priceFeed = _addressesRegistry.priceFeed();

        // Approve coll to BorrowerOperations
        WETH.approve(address(_borrowerOperations), type(uint256).max);

        // Approve Bold to exchange module (Coll is approved in parent WETHZapper)
        boldToken.approve(address(_exchange), type(uint256).max);
    }

    struct OpenLeveragedTroveVars {
        uint256 troveId;
        IBorrowerOperations borrowerOperations;
        IWETH WETH;
        IBoldToken boldToken;
        uint256 boldAmount;
    }

    function openLeveragedTroveWithRawETH(OpenLeveragedTroveParams calldata _params) external payable {
        require(msg.value == ETH_GAS_COMPENSATION + _params.collAmount, "LZ: Wrong amount of ETH");
        require(
            _params.batchManager == address(0) || _params.annualInterestRate == 0,
            "LZ: Cannot choose interest if joining a batch"
        );

        // Set initial balances to make sure there are not lefovers
        InitialBalances memory initialBalances;
        _setInitialBalances(WETH, boldToken, initialBalances);

        // Convert ETH to WETH
        WETH.deposit{value: msg.value}();

        // Flash loan coll
        flashLoanProvider.makeFlashLoan(
            WETH, _params.flashLoanAmount, IFlashLoanProvider.Operation.OpenTrove, abi.encode(_params)
        );

        // return leftovers to user
        _returnLeftovers(initialBalances);
    }

    // Callback from the flash loan provider
    function receiveFlashLoanOnOpenLeveragedTrove(
        OpenLeveragedTroveParams calldata _params,
        uint256 _effectiveFlashLoanAmount
    ) external override {
        require(msg.sender == address(flashLoanProvider), "LZ: Caller not FlashLoan provider");

        OpenLeveragedTroveVars memory vars;
        vars.borrowerOperations = borrowerOperations;
        vars.WETH = WETH;
        vars.boldToken = boldToken;

        uint256 totalCollAmount = _params.collAmount + _effectiveFlashLoanAmount;
        // We compute boldAmount off-chain for efficiency

        // Open trove
        if (_params.batchManager == address(0)) {
            vars.troveId = vars.borrowerOperations.openTrove(
                _params.owner,
                _params.ownerIndex,
                totalCollAmount,
                _params.boldAmount,
                _params.upperHint,
                _params.lowerHint,
                _params.annualInterestRate,
                _params.maxUpfrontFee,
                // Add this contract as add/receive manager to be able to fully adjust trove,
                // while keeping the same management functionality
                address(this), // add manager
                address(this), // remove manager
                address(this) // receiver for remove manager
            );
        } else {
            IBorrowerOperations.OpenTroveAndJoinInterestBatchManagerParams memory
                openTroveAndJoinInterestBatchManagerParams = IBorrowerOperations
                    .OpenTroveAndJoinInterestBatchManagerParams({
                    owner: _params.owner,
                    ownerIndex: _params.ownerIndex,
                    collAmount: totalCollAmount,
                    boldAmount: _params.boldAmount,
                    upperHint: _params.upperHint,
                    lowerHint: _params.lowerHint,
                    interestBatchManager: _params.batchManager,
                    maxUpfrontFee: _params.maxUpfrontFee,
                    // Add this contract as add/receive manager to be able to fully adjust trove,
                    // while keeping the same management functionality
                    addManager: address(this), // add manager
                    removeManager: address(this), // remove manager
                    receiver: address(this) // receiver for remove manager
                });
            vars.troveId =
                vars.borrowerOperations.openTroveAndJoinInterestBatchManager(openTroveAndJoinInterestBatchManagerParams);
        }

        // Set add/remove managers
        _setAddManager(vars.troveId, _params.addManager);
        _setRemoveManagerAndReceiver(vars.troveId, _params.removeManager, _params.receiver);

        // Swap Bold to Coll
        exchange.swapFromBold(_params.boldAmount, _params.flashLoanAmount);

        // Send coll back to return flash loan
        vars.WETH.transfer(address(flashLoanProvider), _params.flashLoanAmount);
        // WETH reverts on failure: https://etherscan.io/token/0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2#code
    }

    function leverUpTrove(LeverUpTroveParams calldata _params) external {
        address owner = troveNFT.ownerOf(_params.troveId);
        _requireSenderIsOwnerOrRemoveManagerAndGetReceiver(_params.troveId, owner);

        // Set initial balances to make sure there are not lefovers
        InitialBalances memory initialBalances;
        _setInitialBalances(WETH, boldToken, initialBalances);

        // Flash loan coll
        flashLoanProvider.makeFlashLoan(
            WETH, _params.flashLoanAmount, IFlashLoanProvider.Operation.LeverUpTrove, abi.encode(_params)
        );

        // return leftovers to user
        _returnLeftovers(initialBalances);
    }

    // Callback from the flash loan provider
    function receiveFlashLoanOnLeverUpTrove(LeverUpTroveParams calldata _params, uint256 _effectiveFlashLoanAmount)
        external
        override
    {
        require(msg.sender == address(flashLoanProvider), "LZ: Caller not FlashLoan provider");

        // Adjust trove
        // With the received coll from flash loan, we increase both the trove coll and debt
        borrowerOperations.adjustTrove(
            _params.troveId,
            _effectiveFlashLoanAmount, // flash loan amount minus fee
            true, // _isCollIncrease
            _params.boldAmount,
            true, // _isDebtIncrease
            _params.maxUpfrontFee
        );

        // Swap Bold to Coll
        // No need to use a min: if the obtained amount is not enough, the flash loan return below won’t be enough
        // And the flash loan provider will revert after this function exits
        // The frontend should calculate in advance the `_params.boldAmount` needed for this to work
        exchange.swapFromBold(_params.boldAmount, _params.flashLoanAmount);

        // Send coll back to return flash loan
        WETH.transfer(address(flashLoanProvider), _params.flashLoanAmount);
    }

    function leverDownTrove(LeverDownTroveParams calldata _params) external {
        address owner = troveNFT.ownerOf(_params.troveId);
        _requireSenderIsOwnerOrRemoveManagerAndGetReceiver(_params.troveId, owner);

        // Set initial balances to make sure there are not lefovers
        InitialBalances memory initialBalances;
        _setInitialBalances(WETH, boldToken, initialBalances);

        // Flash loan coll
        flashLoanProvider.makeFlashLoan(
            WETH, _params.flashLoanAmount, IFlashLoanProvider.Operation.LeverDownTrove, abi.encode(_params)
        );

        // return leftovers to user
        _returnLeftovers(initialBalances);
    }

    // Callback from the flash loan provider
    function receiveFlashLoanOnLeverDownTrove(LeverDownTroveParams calldata _params, uint256 _effectiveFlashLoanAmount)
        external
        override
    {
        require(msg.sender == address(flashLoanProvider), "LZ: Caller not FlashLoan provider");

        // Swap Coll from flash loan to Bold, so we can repay and downsize trove
        // We swap the flash loan minus the flash loan fee
        // The frontend should calculate in advance the `_params.minBoldAmount` to achieve the desired leverage ratio
        // (with some slippage tolerance)
        uint256 receivedBoldAmount = exchange.swapToBold(_effectiveFlashLoanAmount, _params.minBoldAmount);

        // Adjust trove
        borrowerOperations.adjustTrove(
            _params.troveId,
            _params.flashLoanAmount,
            false, // _isCollIncrease
            receivedBoldAmount,
            false, // _isDebtIncrease
            0
        );

        // Send coll back to return flash loan
        WETH.transfer(address(flashLoanProvider), _params.flashLoanAmount);
    }

    // As formulas are symmetrical, it can be used in both ways
    function leverageRatioToCollateralRatio(uint256 _inputRatio) external pure returns (uint256) {
        return _inputRatio * DECIMAL_PRECISION / (_inputRatio - DECIMAL_PRECISION);
    }
}

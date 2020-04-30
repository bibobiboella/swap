/*

    Copyright 2020 dYdX Trading Inc.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import { Ownable } from "@openzeppelin/contracts/ownership/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import { BaseMath } from "../../lib/BaseMath.sol";
import { SignedMath } from "../../lib/SignedMath.sol";
import { I_PerpetualV1 } from "../intf/I_PerpetualV1.sol";
import { P1BalanceMath } from "../lib/P1BalanceMath.sol";
import { P1Types } from "../lib/P1Types.sol";


/**
 * @title P1LiquidatorProxy
 * @author dYdX
 *
 * @notice Proxy contract for liquidating accounts. A fixed percentage of each liquidation is
 * directed to the insurance fund.
 */
contract P1LiquidatorProxy is
    Ownable
{
    using BaseMath for uint256;
    using SignedMath for SignedMath.Int;
    using P1BalanceMath for P1Types.Balance;
    using SafeERC20 for IERC20;

    // ============ Events ============

    event LogLiquidatorProxyUsed(
        address indexed liquidator,
        address indexed liquidatee,
        bool isBuy,
        uint256 liquidationAmount,
        uint256 feeAmount
    );

    event LogInsuranceFundSet(
        address insuranceFund
    );

    // ============ Immutable Storage ============

    // Address of the perpetual contract.
    address public _PERPETUAL_V1_;

    // Address of the P1Liquidation contract.
    address public _LIQUIDATION_;

    // Percentage of liquidated debts that go to the insurance fund after liquidation.
    // This number is represented as a fixed-point number with 18 decimals.
    uint256 public _FEE_PERCENTAGE_;

    // ============ Mutable Storage ============

    // Address of the insurance fund.
    address public _INSURANCE_FUND_;

    // ============ Constructor ============

    constructor (
        address perpetualV1,
        address liquidator,
        address insuranceFund,
        uint256 feePercentage
    )
        public
    {
        _PERPETUAL_V1_ = perpetualV1;
        _LIQUIDATION_ = liquidator;
        _INSURANCE_FUND_ = insuranceFund;
        _FEE_PERCENTAGE_ = feePercentage;

        emit LogInsuranceFundSet(insuranceFund);
    }

    // ============ External Functions ============

    /**
     * @notice Sets the maximum allowance on the perpetual contract. Must be called at least once.
     * @dev Cannot be run in the constructor due to technical restrictions in Solidity.
     */
    function setAllowance()
        external
    {
        address perpetual = _PERPETUAL_V1_;
        IERC20 tokenContract = IERC20(I_PerpetualV1(perpetual).getTokenContract());

        // safeApprove requires unsetting the allowance first.
        tokenContract.safeApprove(perpetual, 0);

        // Set the allowance to the highest possible value.
        tokenContract.safeApprove(perpetual, uint256(-1));
    }

    /**
     * @notice Allows an account below the minimum collateralization to be liquidated by another
     *  account. This allows the account to be partially or fully subsumed by the liquidator.
     * @dev Emits the LogLiquidatorProxyUsed event.
     *
     * @param  liquidatee   The account to liquidate.
     * @param  isBuy        True if the liquidatee has a long position, false otherwise.
     * @param  maxPosition  Maximum position size that the liquidator will take post-liquidation.
     * @return              The change in position.
     */
    function liquidate(
        address liquidatee,
        bool isBuy,
        SignedMath.Int calldata maxPosition
    )
        external
        returns (uint256)
    {
        I_PerpetualV1 perpetual = I_PerpetualV1(_PERPETUAL_V1_);

        // Get the balances of the sender.
        perpetual.deposit(msg.sender, 0);
        P1Types.Balance memory initialBalance = perpetual.getAccountBalance(msg.sender);

        // Get the maximum liquidatable amount.
        SignedMath.Int memory maxPositionDelta = _getMaxPositionDelta(
            initialBalance,
            isBuy,
            maxPosition
        );

        // Do the liquidation.
        _doLiquidation(
            perpetual,
            liquidatee,
            maxPositionDelta
        );

        // Get the balances of the sender.
        P1Types.Balance memory currentBalance = perpetual.getAccountBalance(msg.sender);

        // Get the liquidated amount and fee amount.
        (uint256 liqAmount, uint256 feeAmount) = _getLiquidatedAndFeeAmount(
            perpetual,
            isBuy,
            initialBalance,
            currentBalance
        );

        // Transfer fee from sender to insurance fund.
        perpetual.withdraw(msg.sender, address(this), feeAmount);
        perpetual.deposit(_INSURANCE_FUND_, feeAmount);

        // Log the result.
        emit LogLiquidatorProxyUsed(
            msg.sender,
            liquidatee,
            isBuy,
            liqAmount,
            feeAmount
        );

        return liqAmount;
    }

    // ============ Admin Functions ============

    /**
     * @dev Allows the owner to set the insurance fund address. Emits the LogInsuranceFundSet event.
     *
     * @param  insuranceFund  The address to set as the insurance fund.
     */
    function setInsuranceFund(
        address insuranceFund
    )
        external
        onlyOwner
    {
        _INSURANCE_FUND_ = insuranceFund;
        emit LogInsuranceFundSet(insuranceFund);
    }

    // ============ Helper Functions ============

    /**
     * @dev Calculate (and verify) the maximum amount to liquidate based on the maxPosition input.
     */
    function _getMaxPositionDelta(
        P1Types.Balance memory initialBalance,
        bool isBuy,
        SignedMath.Int memory maxPosition
    )
        private
        pure
        returns (SignedMath.Int memory)
    {
        SignedMath.Int memory result = maxPosition.signedSub(initialBalance.getPosition());

        require(
            result.isPositive == isBuy && result.value > 0,
            "Cannot liquidate past maxPosition"
        );

        return result;
    }

    /**
     * @dev Perform the liquidation by constructing the correct arguments and sending it to the
     * perpetual.
     */
    function _doLiquidation(
        I_PerpetualV1 perpetual,
        address liquidatee,
        SignedMath.Int memory maxPositionDelta
    )
        private
    {
        // Create accounts.
        bool takerFirst = address(msg.sender) < liquidatee;
        address[] memory accounts = new address[](2);
        uint256 takerIndex = takerFirst ? 0 : 1;
        uint256 makerIndex = takerFirst ? 1 : 0;
        accounts[takerIndex] = msg.sender;
        accounts[makerIndex] = liquidatee;

        // Create trade args.
        I_PerpetualV1.TradeArg[] memory trades = new I_PerpetualV1.TradeArg[](1);
        trades[0] = I_PerpetualV1.TradeArg({
            takerIndex: takerIndex,
            makerIndex: makerIndex,
            trader: _LIQUIDATION_,
            data: abi.encode(
                maxPositionDelta.value,
                maxPositionDelta.isPositive,
                false // allOrNothing
            )
        });

        // Do the liquidation.
        perpetual.trade(accounts, trades);
    }

    /**
     * @dev Calculate the liquidated amount and also the fee amount based on a percentage of the
     * value of the repaid debt.
     * @return  The position amount bought or sold.
     * @return  The fee amount in margin token.
     */
    function _getLiquidatedAndFeeAmount(
        I_PerpetualV1 perpetual,
        bool isBuy,
        P1Types.Balance memory initialBalance,
        P1Types.Balance memory currentBalance
    )
        private
        view
        returns (uint256, uint256)
    {
        // Get the amount liquidated.
        uint256 liqAmount = currentBalance.getPosition().signedSub(
            initialBalance.getPosition()
        ).value;

        // Get the value of debt liquidated.
        uint256 debtAmountInMargin = isBuy
            ? currentBalance.getMargin().signedSub(initialBalance.getMargin()).value
            : liqAmount.baseMul(perpetual.getOraclePrice());

        // Calculate the fee (in margin tokens) based on the value of the debt liquidated.
        uint256 feeAmount = debtAmountInMargin.baseMul(_FEE_PERCENTAGE_);

        return (liqAmount, feeAmount);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import { BaseMath } from "./protocol/lib/BaseMath.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { I_Aggregator } from "./external/chainlink/I_Aggregator.sol";
import { I_P1Oracle } from "./protocol/v1/intf/I_P1Oracle.sol";
import { P1Types } from "./protocol/v1/lib/P1Types.sol";
import { SignedMath } from "./protocol/lib/SignedMath.sol";
import { P1BalanceMath } from "./protocol/v1/lib/P1BalanceMath.sol";
//
import { BaseMath } from "./protocol/lib/BaseMath.sol";

/**
 * @title BTCETHPerpetualSwap
 * @author Based on dYdX Trading Inc.
 *
 * @notice A perpetual swap contract for BTC-ETH trading
 */
contract BTCETHPerpetualSwap {
    using SafeMath for uint256;
    using BaseMath for uint256;

    // ============ Constants ============

    // Minimum collateral ratio required (150%)
    uint256 public constant MINIMUM_COLLATERAL_RATIO = 15e16;
    
    // Liquidation fee percentage (5%)
    uint256 public constant LIQUIDATION_FEE = 5e16;
    
    // Maximum funding rate per day (0.75%)
    uint256 public constant MAX_FUNDING_RATE = 75e14;
    
    // Funding period in seconds (8 hours)
    uint256 public constant FUNDING_PERIOD = 8 hours;

    // ============ State Variables ============

    // BTC Price Oracle
    I_Aggregator public btcPriceOracle;
    
    // ETH Price Oracle
    I_Aggregator public ethPriceOracle;
    
    // Mapping of account addresses to their balances
    mapping(address => P1Types.Balance) public balances;

    // Track funding indexes per user
    mapping(address => uint256) public userFundingIndexes;
    
    // Total open interest
    uint256 public totalLongPositions;
    uint256 public totalShortPositions;
    
    // Last funding time
    uint256 public lastFundingTime;
    
    // Cumulative funding rate
    SignedMath.Int public cumulativeFundingRate;
    
    // Contract owner
    address public owner;
    
    // Is trading paused
    bool public isPaused;
    
    // ETH token used for margin
    IERC20 public marginToken;

    // ============ Events ============

    event PositionOpened(
        address indexed trader,
        bool isLong,
        uint256 amount,
        uint256 price,
        uint256 margin
    );
    
    event PositionClosed(
        address indexed trader,
        bool isLong,
        uint256 amount,
        uint256 price,
        uint256 margin,
        uint256 pnl
    );
    
    event PositionLiquidated(
        address indexed trader,
        address indexed liquidator,
        uint256 amount,
        uint256 price,
        uint256 liquidationFee
    );
    
    event FundingRateUpdated(
        bool isPositive,
        uint256 rate,
        uint256 timestamp
    );
    
    event MarginAdded(
        address indexed trader,
        uint256 amount
    );
    
    event MarginWithdrawn(
        address indexed trader,
        uint256 amount
    );

    // ============ Modifiers ============

    modifier onlyOwner() {
        require(msg.sender == owner, "BTCETHPerpetualSwap: caller is not the owner");
        _;
    }
    
    modifier whenNotPaused() {
        require(!isPaused, "BTCETHPerpetualSwap: trading is paused");
        _;
    }
    
    modifier validPosition(uint256 amount) {
        require(amount > 0, "BTCETHPerpetualSwap: position amount must be greater than zero");
        _;
    }

    // ============ Constructor ============

    constructor(
        address _btcPriceOracle,
        address _ethPriceOracle,
        address _marginToken
    ) 
        public 
    {
        owner = msg.sender;
        btcPriceOracle = I_Aggregator(_btcPriceOracle);
        ethPriceOracle = I_Aggregator(_ethPriceOracle);
        marginToken = IERC20(_marginToken);
        lastFundingTime = block.timestamp;
        cumulativeFundingRate = SignedMath.Int({
            value: 0,
            isPositive: true
        });
    }

    // ============ Public Functions ============

    /**
     * @notice Opens a new perpetual swap position
     * @param isLong True for long position, false for short
     * @param amount Position size in BTC (scaled by 1e18)
     * @param marginAmount Initial margin amount in ETH (scaled by 1e18)
     */
    function openPosition(
        bool isLong,
        uint256 amount,
        uint256 marginAmount
    )
        external
        whenNotPaused
        validPosition(amount)
    {
        // Apply funding if needed
        updateFundingRate();
        
        // Get current BTC/ETH price
        uint256 price = getPrice();
        
        // Transfer margin from user
        require(
            marginToken.transferFrom(msg.sender, address(this), marginAmount),
            "BTCETHPerpetualSwap: margin transfer failed"
        );
        
        // Initialize or update user's balance
        P1Types.Balance storage balance = balances[msg.sender];
        
        // Apply funding to user
        applyFunding(balance);
        
        // Add margin
        P1BalanceMath.addToMargin(balance, marginAmount);
        
        // Update position
        if (isLong) {
            P1BalanceMath.addToPosition(balance, amount);
            totalLongPositions = totalLongPositions.add(amount);
        } else {
            uint256 currentPosition = balance.position;
            if (balance.positionIsPositive) {
                // Current position is long
                if (currentPosition > amount) {
                    // Reducing long position
                    P1BalanceMath.subFromPosition(balance, amount);
                    totalLongPositions = totalLongPositions.sub(amount);
                } else {
                    // Flipping to short
                    P1BalanceMath.setPosition(
                        balance,
                        SignedMath.Int({
                            value: amount.sub(currentPosition),
                            isPositive: true
                        })
                    );
                    totalLongPositions = totalLongPositions.sub(currentPosition);
                    totalShortPositions = totalShortPositions.add(amount.sub(currentPosition));
                }
            } else {
                // Current position is short, increasing it
                P1BalanceMath.addToPosition(balance, amount);
                totalShortPositions = totalShortPositions.add(amount);
            }
        }
        
        // Check that the position is properly collateralized
        require(
            isCollateralized(balance, price),
            "BTCETHPerpetualSwap: position undercollateralized"
        );
        
        emit PositionOpened(
            msg.sender,
            isLong,
            amount,
            price,
            marginAmount
        );
    }
    
    /**
     * @notice Closes an existing perpetual swap position
     * @param amount Amount of position to close
     */
    function closePosition(
        uint256 amount
    )
        external
        whenNotPaused
        validPosition(amount)
    {
        // Apply funding if needed
        updateFundingRate();
        
        // Get current BTC/ETH price
        uint256 price = getPrice();
        
        // Get user's balance
        P1Types.Balance storage balance = balances[msg.sender];
        
        // Verify position exists
        require(
            balance.position > 0,
            "BTCETHPerpetualSwap: no position to close"
        );
        require(
            amount <= balance.position,
            "BTCETHPerpetualSwap: closing amount exceeds position"
        );
        
        // Apply funding to user
        applyFunding(balance);
        
        // Calculate P&L
        uint256 entryPrice = balance.margin;
        uint256 pnl;
        bool isLong = balance.positionIsPositive;
        
        if (isLong) {
            // Long position: PnL = (currentPrice - entryPrice) * size
            if (price > entryPrice) {
                pnl = amount.mul(price.sub(entryPrice)).div(price);
            } else {
                pnl = amount.mul(entryPrice.sub(price)).div(price);
            }
            totalLongPositions = totalLongPositions.sub(amount);
        } else {
            // Short position: PnL = (entryPrice - currentPrice) * size
            if (entryPrice > price) {
                pnl = amount.mul(entryPrice.sub(price)).div(price);
            } else {
                pnl = amount.mul(price.sub(entryPrice)).div(price);
            }
            totalShortPositions = totalShortPositions.sub(amount);
        }
        
        // Update position
        P1BalanceMath.subFromPosition(balance, amount);
        
        // Update margin (add PnL if profitable, subtract if loss)
        if ((isLong && price > entryPrice) || (!isLong && entryPrice > price)) {
            // Profit
            P1BalanceMath.addToMargin(balance, pnl);
        } else {
            // Loss
            P1BalanceMath.subFromMargin(balance, pnl);
        }
        
        // Transfer realized profits back to user
        if ((isLong && price > entryPrice) || (!isLong && entryPrice > price)) {
            require(
                marginToken.transfer(msg.sender, pnl),
                "BTCETHPerpetualSwap: profit transfer failed"
            );
        }
        
        emit PositionClosed(
            msg.sender,
            isLong,
            amount,
            price,
            balance.margin,
            pnl
        );
    }
    
    /**
     * @notice Liquidates an undercollateralized position
     * @param trader Address of the trader to liquidate
     */
    function liquidatePosition(
        address trader
    )
        external
        whenNotPaused
    {
        // Apply funding if needed
        updateFundingRate();
        
        // Get current BTC/ETH price
        uint256 price = getPrice();
        
        // Get trader's balance
        P1Types.Balance storage balance = balances[trader];
        
        // Verify position is undercollateralized
        require(
            !isCollateralized(balance, price),
            "BTCETHPerpetualSwap: position is properly collateralized"
        );
        
        // Apply funding to trader
        applyFunding(balance);
        
        // Calculate liquidation fee
        uint256 notionalValue = BaseMath.baseMul(balance.position, price);
        //uint256 notionalValue = balance.position.baseMul(price);
        uint256 liquidationFee = notionalValue.baseMul(LIQUIDATION_FEE);
        
        // Ensure liquidation fee doesn't exceed margin
        if (liquidationFee > balance.margin) {
            liquidationFee = balance.margin;
        }
        
        // Transfer liquidation fee to liquidator
        require(
            marginToken.transfer(msg.sender, liquidationFee),
            "BTCETHPerpetualSwap: liquidation fee transfer failed"
        );
        
        // Update global stats
        if (balance.positionIsPositive) {
            totalLongPositions = totalLongPositions.sub(balance.position);
        } else {
            totalShortPositions = totalShortPositions.sub(balance.position);
        }
        
        // Close the position
        P1BalanceMath.setPosition(
            balance,
            SignedMath.Int({
                value: 0,
                isPositive: false
            })
        );
        
        // Reduce margin by liquidation fee
        P1BalanceMath.subFromMargin(balance, liquidationFee);
        
        emit PositionLiquidated(
            trader,
            msg.sender,
            balance.position,
            price,
            liquidationFee
        );
    }
    
    /**
     * @notice Add margin to an existing position
     * @param marginAmount Amount of margin to add
     */
    function addMargin(
        uint256 marginAmount
    )
        external
        whenNotPaused
    {
        // Get user's balance
        P1Types.Balance storage balance = balances[msg.sender];
        
        // Apply funding to user
        applyFunding(balance);
        
        // Transfer margin from user
        require(
            marginToken.transferFrom(msg.sender, address(this), marginAmount),
            "BTCETHPerpetualSwap: margin transfer failed"
        );
        
        // Add to margin
        P1BalanceMath.addToMargin(balance, marginAmount);
        
        emit MarginAdded(
            msg.sender,
            marginAmount
        );
    }
    
    /**
     * @notice Withdraw excess margin from a position
     * @param marginAmount Amount of margin to withdraw
     */
    function withdrawMargin(
        uint256 marginAmount
    )
        external
        whenNotPaused
    {
        // Apply funding if needed
        updateFundingRate();
        
        // Get current BTC/ETH price
        uint256 price = getPrice();
        
        // Get user's balance
        P1Types.Balance storage balance = balances[msg.sender];
        
        // Apply funding to user
        applyFunding(balance);
        
        require(
            marginAmount <= balance.margin,
            "BTCETHPerpetualSwap: withdrawal exceeds available margin"
        );
        
        // Reduce margin
        P1BalanceMath.subFromMargin(balance, marginAmount);
        
        // Check that the position remains properly collateralized
        if (balance.position > 0) {
            require(
                isCollateralized(balance, price),
                "BTCETHPerpetualSwap: withdrawal would undercollateralize position"
            );
        }
        
        // Transfer margin to user
        require(
            marginToken.transfer(msg.sender, marginAmount),
            "BTCETHPerpetualSwap: margin transfer failed"
        );
        
        emit MarginWithdrawn(
            msg.sender,
            marginAmount
        );
    }
    
    /**
     * @notice Get current position details
     * @param trader Address of the trader
     * @return positionSize Size of the position
     * @return isLong Whether the position is long
     * @return marginAmount Amount of margin
     * @return entryPrice Entry price of the position
     */
    function getPosition(
        address trader
    )
        external
        view
        returns (
            uint256 positionSize,
            bool isLong,
            uint256 marginAmount,
            uint256 entryPrice
        )
    {
        P1Types.Balance storage balance = balances[trader];
        return (
            balance.position,
            balance.positionIsPositive,
            balance.margin,
            balance.margin
        );
    }
    
    /**
     * @notice Calculate the PnL of a position
     * @param trader Address of the trader
     * @return pnl Unrealized PnL (positive for profit, negative for loss)
     */
    function getUnrealizedPnL(
        address trader
    )
        external
        view
        returns (int256)
    {
        P1Types.Balance storage balance = balances[trader];
        
        if (balance.position == 0) {
            return 0;
        }
        
        uint256 currentPrice = getPrice();
        uint256 entryPrice = balance.margin;
        uint256 amount = balance.position;
        bool isLong = balance.positionIsPositive;
        
        int256 pnl;
        
        if (isLong) {
            // Long position: PnL = (currentPrice - entryPrice) * size
            if (currentPrice > entryPrice) {
                pnl = int256(amount.mul(currentPrice.sub(entryPrice)).div(currentPrice));
            } else {
                pnl = -int256(amount.mul(entryPrice.sub(currentPrice)).div(currentPrice));
            }
        } else {
            // Short position: PnL = (entryPrice - currentPrice) * size
            if (entryPrice > currentPrice) {
                pnl = int256(amount.mul(entryPrice.sub(currentPrice)).div(currentPrice));
            } else {
                pnl = -int256(amount.mul(currentPrice.sub(entryPrice)).div(currentPrice));
            }
        }
        
        return pnl;
    }

    // ============ Admin Functions ============

    /**
     * @notice Pause trading
     */
    function pause()
        external
        onlyOwner
    {
        isPaused = true;
    }
    
    /**
     * @notice Resume trading
     */
    function unpause()
        external
        onlyOwner
    {
        isPaused = false;
    }
    
    /**
     * @notice Update the BTC price oracle
     * @param _btcPriceOracle New BTC price oracle address
     */
    function setBtcPriceOracle(
        address _btcPriceOracle
    )
        external
        onlyOwner
    {
        btcPriceOracle = I_Aggregator(_btcPriceOracle);
    }
    
    /**
     * @notice Update the ETH price oracle
     * @param _ethPriceOracle New ETH price oracle address
     */
    function setEthPriceOracle(
        address _ethPriceOracle
    )
        external
        onlyOwner
    {
        ethPriceOracle = I_Aggregator(_ethPriceOracle);
    }
    
    /**
     * @notice Withdraw fees collected by the contract
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function withdrawFees(
        uint256 amount,
        address recipient
    )
        external
        onlyOwner
    {
        // Calculate available fees (total balance - user margins)
        uint256 contractBalance = marginToken.balanceOf(address(this));
        uint256 totalUserMargin = 0;
        
        // This is a simplified approach - in production you would 
        // maintain a separate accounting of fees
        
        require(
            amount <= contractBalance.sub(totalUserMargin),
            "BTCETHPerpetualSwap: withdrawal exceeds available fees"
        );
        
        require(
            marginToken.transfer(recipient, amount),
            "BTCETHPerpetualSwap: fee transfer failed"
        );
    }

    // ============ Internal Functions ============

    /**
     * @notice Get the current BTC/ETH price
     * @return Current BTC/ETH price (scaled by 1e18)
     */
    function getPrice()
        internal
        view
        returns (uint256)
    {
        // Get BTC price in USD
        int256 btcPrice = btcPriceOracle.latestAnswer();
        require(btcPrice > 0, "BTCETHPerpetualSwap: invalid BTC price");
        
        // Get ETH price in USD
        int256 ethPrice = ethPriceOracle.latestAnswer();
        require(ethPrice > 0, "BTCETHPerpetualSwap: invalid ETH price");
        
        // Calculate BTC/ETH price with 18 decimals
        return uint256(btcPrice).mul(1e18).div(uint256(ethPrice));
    }
    
    /**
     * @notice Check if a position is properly collateralized
     * @param balance User's balance
     * @param price Current BTC/ETH price
     * @return True if the position is properly collateralized
     */
    function isCollateralized(
        P1Types.Balance storage balance,
        uint256 price
    )
        internal
        view
        returns (bool)
    {
        if (balance.position == 0) {
            return true;
        }
        
        // Calculate notional value of the position
        uint256 notionalValue = BaseMath.baseMul(balance.position, price);
        
        
        // Calculate required margin
        uint256 requiredMargin = notionalValue.baseMul(MINIMUM_COLLATERAL_RATIO);
        
        // Check if margin is sufficient
        return balance.margin >= requiredMargin;
    }
    
    /**
     * @notice Update the funding rate
     */
    function updateFundingRate()
        internal
    {
        uint256 currentTime = block.timestamp;
        uint256 timeDelta = currentTime.sub(lastFundingTime);
        
        if (timeDelta >= FUNDING_PERIOD) {
            // Calculate funding rate based on imbalance between longs and shorts
            uint256 longValue = totalLongPositions.baseMul(getPrice());
            uint256 shortValue = totalShortPositions.baseMul(getPrice());
            
            bool isPositive;
            uint256 fundingRate;
            
            if (longValue > shortValue && longValue > 0) {
                // More longs than shorts, longs pay shorts
                isPositive = true;
                fundingRate = MAX_FUNDING_RATE.mul(longValue.sub(shortValue)).div(longValue);
            } else if (shortValue > longValue && shortValue > 0) {
                // More shorts than longs, shorts pay longs
                isPositive = false;
                fundingRate = MAX_FUNDING_RATE.mul(shortValue.sub(longValue)).div(shortValue);
            } else {
                // Balanced or no positions, no funding
                isPositive = false;
                fundingRate = 0;
            }
            
            // Calculate time-weighted funding rate
            uint256 periods = timeDelta.div(FUNDING_PERIOD);
            fundingRate = fundingRate.mul(periods);
            
            // Update cumulative funding rate
            if (isPositive == cumulativeFundingRate.isPositive) {
                // Signs are opposite, subtract
                if (fundingRate > cumulativeFundingRate.value) {
                    cumulativeFundingRate.value = fundingRate.sub(cumulativeFundingRate.value);
                    cumulativeFundingRate.isPositive = !isPositive;
                } else {
                    cumulativeFundingRate.value = cumulativeFundingRate.value.sub(fundingRate);
                }
            } else {
                // Signs are the same, add
                cumulativeFundingRate.value = cumulativeFundingRate.value.add(fundingRate);
            }
            
            lastFundingTime = currentTime;
            
            emit FundingRateUpdated(
                isPositive,
                fundingRate,
                currentTime
            );
        }
    }
    
    /**
 * @notice Apply funding to a user's position
 * @param balance User's balance
 */
function applyFunding(
    P1Types.Balance storage balance
)
    internal
{
    address user = msg.sender;
    
    if (balance.position == 0 || userFundingIndexes[user] == cumulativeFundingRate.value) {
        // No position or already up to date
        userFundingIndexes[user] = cumulativeFundingRate.value;
        return;
    }
    
    uint256 fundingDelta;
    if (userFundingIndexes[user] < cumulativeFundingRate.value) {
        fundingDelta = cumulativeFundingRate.value.sub(userFundingIndexes[user]);
    } else {
        fundingDelta = userFundingIndexes[user].sub(cumulativeFundingRate.value);
    }
    
    if (fundingDelta == 0) {
        return;
    }
    
    // Calculate funding payment
    uint256 payment = BaseMath.baseMul(balance.position, fundingDelta);
    
    // Apply funding based on position side and funding rate direction
    bool shouldPayFunding = (balance.positionIsPositive == !cumulativeFundingRate.isPositive);
    
    if (shouldPayFunding) {
        // User pays funding
        P1BalanceMath.subFromMargin(balance, payment);
    } else {
        // User receives funding
        P1BalanceMath.addToMargin(balance, payment);
    }
    
    // Update funding index
    userFundingIndexes[user] = cumulativeFundingRate.value;
}
}
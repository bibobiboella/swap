// SPDX-License-Identifier: MIT
pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

/**
 * @title MarginEnabledBTCETHPerpetualSwap
 * @notice 带有保证金要求的BTC-ETH永续合约
 */
contract MarginEnabledBTCETHPerpetualSwap {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // ============ 事件 ============
    event PositionOpened(address indexed trader, bool isLong, uint256 amount, uint256 entryPrice, uint256 collateral);
    event PositionClosed(address indexed trader, bool isLong, uint256 amount, uint256 exitPrice, int256 pnl);
    event CollateralAdded(address indexed trader, uint256 amount);
    event CollateralRemoved(address indexed trader, uint256 amount);
    event Liquidated(address indexed trader, address liquidator, uint256 positionSize, uint256 collateral);
    event FundingPaid(address indexed trader, int256 amount);

    // ============ 数据结构 ============
    struct Position {
        uint256 size;                // 头寸大小
        bool isLong;                 // 是否做多
        uint256 entryPrice;          // 入场价格
        uint256 collateral;          // 保证金数量（以ETH计价）
        uint256 lastFundingIndex;    // 上次结算的资金费率索引
    }

    // ============ 状态变量 ============
    // 保证金要求比例（以基点表示，1% = 100个基点）
    uint256 public constant INITIAL_MARGIN_RATIO = 500;    // 5% 初始保证金
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 300; // 3% 维持保证金
    uint256 public constant LIQUIDATION_REWARD = 100;      // 1% 清算奖励

    // 价格预言机 (简化版模拟)
    uint256 public btcPrice = 40000e18;  // BTC 价格，美元计价
    uint256 public ethPrice = 2000e18;   // ETH 价格，美元计价
    
    // 全局统计
    uint256 public totalLongPositions;
    uint256 public totalShortPositions;
    
    // 用户头寸
    mapping(address => Position) public positions;
    
    // 资金费率
    uint256 public cumulativeFundingIndex;
    uint256 public lastFundingTime;
    uint256 public constant FUNDING_PERIOD = 8 hours;
    uint256 public constant FUNDING_RATE = 1e15; // 0.1% 每周期
    
    // 交易手续费
    uint256 public constant TRADING_FEE = 1e15; // 0.1%
    
    // 合约拥有者
    address public owner;
    
    // 交易启用/暂停
    bool public tradingPaused;
    
    // 保证金代币（使用ETH作为抵押品）
    IERC20 public collateralToken;

    // 清算资金池
    uint256 public insuranceFund;
    
    // 手续费接收地址
    address public feeRecipient;

    // ============ 修饰符 ============
    modifier onlyOwner() {
        require(msg.sender == owner, "只有合约拥有者可以调用此函数");
        _;
    }
    
    modifier whenNotPaused() {
        require(!tradingPaused, "交易已暂停");
        _;
    }

    // ============ 构造函数 ============
    constructor(address _feeRecipient, address _collateralToken) public {
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        lastFundingTime = block.timestamp;
        collateralToken = IERC20(_collateralToken);
    }

    // ============ 公共函数 ============
    /**
     * @notice 开启一个永续合约头寸
     * @param isLong 是否做多
     * @param amount 头寸大小
     * @param collateralAmount 抵押品数量
     */
    function openPosition(bool isLong, uint256 amount, uint256 collateralAmount) external whenNotPaused {
        require(amount > 0, "头寸大小必须大于0");
        
        // 更新资金费率
        updateFunding();
        
        // 获取当前BTC/ETH价格
        uint256 price = getBtcEthPrice();
        
        // 获取用户当前头寸
        Position storage position = positions[msg.sender];
        
        // 如果用户已有头寸，先结算资金费率
        if (position.size > 0) {
            settleFunding(msg.sender);
        }
        
        // 接收抵押品
        if (collateralAmount > 0) {
            collateralToken.safeTransferFrom(msg.sender, address(this), collateralAmount);
            
            // 更新用户抵押品
            position.collateral = position.collateral.add(collateralAmount);
        }
        
        // 如果用户已有头寸且方向相同，则合并头寸
        if (position.size > 0 && position.isLong == isLong) {
            // 计算新的平均入场价格
            position.entryPrice = (position.entryPrice.mul(position.size).add(price.mul(amount))).div(position.size.add(amount));
            position.size = position.size.add(amount);
        } 
        // 如果用户已有头寸但方向不同，则减少或翻转头寸
        else if (position.size > 0 && position.isLong != isLong) {
            if (position.size > amount) {
                // 减少相反方向的头寸
                position.size = position.size.sub(amount);
            } else if (position.size < amount) {
                // 翻转头寸方向
                position.size = amount.sub(position.size);
                position.isLong = isLong;
                position.entryPrice = price;
            } else {
                // 头寸完全抵消
                position.size = 0;
            }
        } 
        // 如果用户没有头寸，创建新头寸
        else {
            position.size = amount;
            position.isLong = isLong;
            position.entryPrice = price;
        }
        
        // 检查初始保证金要求
        require(isCollateralSufficient(msg.sender, INITIAL_MARGIN_RATIO), "初始保证金不足");
        
        // 更新全局状态
        if (isLong) {
            totalLongPositions = totalLongPositions.add(amount);
        } else {
            totalShortPositions = totalShortPositions.add(amount);
        }
        
        // 更新用户最后的资金费率索引
        position.lastFundingIndex = cumulativeFundingIndex;
        
        emit PositionOpened(msg.sender, isLong, amount, price, position.collateral);
    }
    
    /**
     * @notice 关闭一个永续合约头寸
     * @param amount 要关闭的头寸大小
     */
    function closePosition(uint256 amount) external whenNotPaused {
        Position storage position = positions[msg.sender];
        
        require(position.size > 0, "没有可关闭的头寸");
        require(amount > 0 && amount <= position.size, "无效的关闭金额");
        
        // 更新资金费率
        updateFunding();
        
        // 结算资金费率
        settleFunding(msg.sender);
        
        // 获取当前价格
        uint256 price = getBtcEthPrice();
        
        // 计算PNL
        int256 pnl;
        if (position.isLong) {
            // 多头：PNL = (退出价格 - 入场价格) * 数量
            if (price > position.entryPrice) {
                pnl = int256(amount.mul(price.sub(position.entryPrice)).div(1e18));
            } else {
                pnl = -int256(amount.mul(position.entryPrice.sub(price)).div(1e18));
            }
            totalLongPositions = totalLongPositions.sub(amount);
        } else {
            // 空头：PNL = (入场价格 - 退出价格) * 数量
            if (position.entryPrice > price) {
                pnl = int256(amount.mul(position.entryPrice.sub(price)).div(1e18));
            } else {
                pnl = -int256(amount.mul(price.sub(position.entryPrice)).div(1e18));
            }
            totalShortPositions = totalShortPositions.sub(amount);
        }
        
        // 更新头寸大小
        position.size = position.size.sub(amount);
        
        // 如果头寸完全关闭，返还剩余抵押品
        if (position.size == 0) {
            uint256 collateralToReturn = position.collateral;
            position.collateral = 0;
            
            // 转移抵押品回用户
            collateralToken.safeTransfer(msg.sender, collateralToReturn);
            
            // 删除头寸数据
            delete positions[msg.sender];
        } else {
            // 检查剩余头寸的维持保证金
            require(isCollateralSufficient(msg.sender, MAINTENANCE_MARGIN_RATIO), "关闭部分头寸后，剩余保证金不足");
        }
        
        emit PositionClosed(msg.sender, position.isLong, amount, price, pnl);
    }
    
    /**
     * @notice 增加保证金
     * @param amount 要增加的保证金数量
     */
    function addCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "金额必须大于0");
        
        Position storage position = positions[msg.sender];
        
        // 转移抵押品到合约
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // 更新保证金
        position.collateral = position.collateral.add(amount);
        
        emit CollateralAdded(msg.sender, amount);
    }
    
    /**
     * @notice 移除保证金
     * @param amount 要移除的保证金数量
     */
    function removeCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "金额必须大于0");
        
        Position storage position = positions[msg.sender];
        require(position.collateral >= amount, "保证金不足");
        
        // 更新资金费率
        updateFunding();
        
        // 结算资金费率
        settleFunding(msg.sender);
        
        // 减少保证金
        position.collateral = position.collateral.sub(amount);
        
        // 检查维持保证金要求
        require(isCollateralSufficient(msg.sender, MAINTENANCE_MARGIN_RATIO), "移除后保证金不足");
        
        // 转移抵押品给用户
        collateralToken.safeTransfer(msg.sender, amount);
        
        emit CollateralRemoved(msg.sender, amount);
    }
    
    /**
     * @notice 清算不足担保的头寸
     * @param trader 要清算的交易者地址
     */
    function liquidate(address trader) external whenNotPaused {
        Position storage position = positions[trader];
        
        require(position.size > 0, "目标没有开仓");
        
        // 更新资金费率
        updateFunding();
        
        // 结算资金费率
        settleFunding(trader);
        
        // 检查是否满足清算条件
        require(!isCollateralSufficient(trader, MAINTENANCE_MARGIN_RATIO), "目标保证金充足，无法清算");
        
        // 记录清算信息
        uint256 positionSize = position.size;
        uint256 collateral = position.collateral;
        bool isLong = position.isLong;
        
        // 清算奖励（给清算者）
        uint256 liquidationReward = positionSize.mul(LIQUIDATION_REWARD).div(10000);
        
        // 剩余抵押品归入保险基金
        uint256 remainingCollateral = collateral > liquidationReward ? collateral.sub(liquidationReward) : 0;
        
        // 更新全局头寸
        if (isLong) {
            totalLongPositions = totalLongPositions.sub(positionSize);
        } else {
            totalShortPositions = totalShortPositions.sub(positionSize);
        }
        
        // 转移清算奖励给清算者
        if (liquidationReward > 0) {
            collateralToken.safeTransfer(msg.sender, liquidationReward);
        }
        
        // 将剩余抵押品添加到保险基金
        insuranceFund = insuranceFund.add(remainingCollateral);
        
        // 删除头寸
        delete positions[trader];
        
        emit Liquidated(trader, msg.sender, positionSize, collateral);
    }
    
    /**
     * @notice 查询用户当前头寸信息
     */
    function getPosition(address trader) external view returns (
        uint256 size,
        bool isLong,
        uint256 entryPrice,
        uint256 collateral,
        int256 unrealizedPnl,
        int256 pendingFunding,
        uint256 collateralRatio,
        bool canBeLiquidated
    ) {
        Position storage position = positions[trader];
        
        size = position.size;
        isLong = position.isLong;
        entryPrice = position.entryPrice;
        collateral = position.collateral;
        
        if (size == 0) {
            return (0, false, 0, 0, 0, 0, 0, false);
        }
        
        // 计算未实现盈亏
        uint256 currentPrice = getBtcEthPrice();
        if (isLong) {
            if (currentPrice > entryPrice) {
                unrealizedPnl = int256(size.mul(currentPrice.sub(entryPrice)).div(1e18));
            } else {
                unrealizedPnl = -int256(size.mul(entryPrice.sub(currentPrice)).div(1e18));
            }
        } else {
            if (entryPrice > currentPrice) {
                unrealizedPnl = int256(size.mul(entryPrice.sub(currentPrice)).div(1e18));
            } else {
                unrealizedPnl = -int256(size.mul(currentPrice.sub(entryPrice)).div(1e18));
            }
        }
        
        // 计算待结算的资金费率
        pendingFunding = calculatePendingFunding(trader);
        
        // 计算有效抵押品（考虑未实现盈亏和待结算资金费）
        int256 effectiveCollateral = int256(collateral);
        effectiveCollateral = effectiveCollateral + unrealizedPnl + pendingFunding;
        
        // 计算抵押品比率
        uint256 positionValue = size.mul(currentPrice).div(1e18);
        collateralRatio = effectiveCollateral > 0 ? 
            uint256(effectiveCollateral).mul(10000).div(positionValue) : 0;
        
        // 检查是否可以被清算
        canBeLiquidated = collateralRatio < MAINTENANCE_MARGIN_RATIO;
        
        return (size, isLong, entryPrice, collateral, unrealizedPnl, pendingFunding, collateralRatio, canBeLiquidated);
    }
    
    // ============ 内部函数 ============
    /**
     * @notice 获取当前BTC/ETH价格
     */
    function getBtcEthPrice() public view returns (uint256) {
        return btcPrice.mul(1e18).div(ethPrice);
    }
    
    /**
     * @notice 检查用户的抵押品是否足够
     */
    function isCollateralSufficient(address trader, uint256 requiredRatio) internal view returns (bool) {
        Position storage position = positions[trader];
        
        if (position.size == 0) {
            return true;
        }
        
        // 获取当前价格
        uint256 currentPrice = getBtcEthPrice();
        
        // 计算未实现盈亏
        int256 unrealizedPnl;
        if (position.isLong) {
            if (currentPrice > position.entryPrice) {
                unrealizedPnl = int256(position.size.mul(currentPrice.sub(position.entryPrice)).div(1e18));
            } else {
                unrealizedPnl = -int256(position.size.mul(position.entryPrice.sub(currentPrice)).div(1e18));
            }
        } else {
            if (position.entryPrice > currentPrice) {
                unrealizedPnl = int256(position.size.mul(position.entryPrice.sub(currentPrice)).div(1e18));
            } else {
                unrealizedPnl = -int256(position.size.mul(currentPrice.sub(position.entryPrice)).div(1e18));
            }
        }
        
        // 计算待结算的资金费率
        int256 pendingFunding = calculatePendingFunding(trader);
        
        // 计算有效抵押品（考虑未实现盈亏和待结算资金费）
        int256 effectiveCollateral = int256(position.collateral);
        effectiveCollateral = effectiveCollateral + unrealizedPnl + pendingFunding;
        
        // 如果有效抵押品为负，抵押不足
        if (effectiveCollateral <= 0) {
            return false;
        }
        
        // 计算头寸价值
        uint256 positionValue = position.size.mul(currentPrice).div(1e18);
        
        // 检查抵押品比率是否满足要求
        return uint256(effectiveCollateral).mul(10000).div(positionValue) >= requiredRatio;
    }
    
    /**
     * @notice 更新价格（仅供测试使用）
     */
    function updatePrices(uint256 _btcPrice, uint256 _ethPrice) external onlyOwner {
        btcPrice = _btcPrice;
        ethPrice = _ethPrice;
    }
    
    /**
     * @notice 更新资金费率
     */
    function updateFunding() public {
        uint256 currentTime = block.timestamp;
        uint256 timeDelta = currentTime.sub(lastFundingTime);
        
        if (timeDelta >= FUNDING_PERIOD) {
            uint256 periods = timeDelta.div(FUNDING_PERIOD);
            
            // 基于长短头寸不平衡计算资金费率
            if (totalLongPositions > 0 || totalShortPositions > 0) {
                uint256 fundingRate = FUNDING_RATE.mul(periods);
                cumulativeFundingIndex = cumulativeFundingIndex.add(fundingRate);
            }
            
            lastFundingTime = currentTime;
        }
    }
    
    /**
     * @notice 结算资金费率
     */
    function settleFunding(address trader) internal {
        Position storage position = positions[trader];
        
        if (position.size == 0) {
            return;
        }
        
        int256 fundingPayment = calculatePendingFunding(trader);
        
        // 更新最后的资金费率索引
        position.lastFundingIndex = cumulativeFundingIndex;
        
        // 更新抵押品（根据资金费用增减）
        if (fundingPayment > 0) {
            // 接收资金费
            position.collateral = position.collateral.add(uint256(fundingPayment));
        } else if (fundingPayment < 0) {
            // 支付资金费
            uint256 paymentAbs = uint256(-fundingPayment);
            // 如果抵押品不足以支付资金费，则取最大可用
            if (paymentAbs > position.collateral) {
                paymentAbs = position.collateral;
            }
            position.collateral = position.collateral.sub(paymentAbs);
        }
        
        emit FundingPaid(trader, fundingPayment);
    }
    
    /**
     * @notice 计算待结算的资金费率
     */
    function calculatePendingFunding(address trader) internal view returns (int256) {
        Position storage position = positions[trader];
        
        if (position.size == 0) {
            return 0;
        }
        
        uint256 fundingDelta = cumulativeFundingIndex.sub(position.lastFundingIndex);
        
        if (fundingDelta == 0) {
            return 0;
        }
        
        // 计算基于头寸大小的资金费率
        uint256 payment = position.size.mul(fundingDelta).div(1e18);
        
        // 多头付费给空头（当长头寸 > 短头寸时）
        if (totalLongPositions > totalShortPositions) {
            return position.isLong ? -int256(payment) : int256(payment);
        } 
        // 空头付费给多头（当短头寸 > 长头寸时）
        else if (totalShortPositions > totalLongPositions) {
            return position.isLong ? int256(payment) : -int256(payment);
        }
        
        return 0;
    }
    
    // ============ 管理函数 ============
    /**
     * @notice 从保险基金中提取资金（仅限所有者）
     */
    function withdrawFromInsuranceFund(uint256 amount) external onlyOwner {
        require(amount <= insuranceFund, "保险基金余额不足");
        
        insuranceFund = insuranceFund.sub(amount);
        collateralToken.safeTransfer(owner, amount);
    }
    
    /**
     * @notice 暂停交易
     */
    function pauseTrading() external onlyOwner {
        tradingPaused = true;
    }
    
    /**
     * @notice 恢复交易
     */
    function resumeTrading() external onlyOwner {
        tradingPaused = false;
    }
    
    /**
     * @notice 更新手续费接收地址
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }
    
    /**
     * @notice 转移合约所有权
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "新拥有者不能是零地址");
        owner = newOwner;
    }
}
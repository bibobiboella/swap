// SPDX-License-Identifier: MIT
pragma solidity 0.5.16;
//pragma experimental ABIEncoderV2;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

/**
 * @title BitcoinHedgingStrategy
 * @notice 使用永续合约对冲比特币现货头寸的策略合约
 * @dev 此合约实现了一个简单的对冲策略：持有BTC现货同时在永续合约上做空相同数量，以对冲价格风险
 */
contract BitcoinHedgingStrategy {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // ============ 事件 ============
    event HedgePositionCreated(uint256 spotAmount, uint256 perpetualAmount, uint256 spotPrice);
    event HedgePositionAdjusted(uint256 newSpotAmount, uint256 newPerpetualAmount, uint256 spotPrice);
    event HedgePositionClosed(uint256 spotAmount, uint256 perpetualAmount, uint256 spotPrice, int256 totalPnL);
    event CollateralAdded(uint256 amount);
    event CollateralRemoved(uint256 amount);
    event ProfitTaken(uint256 amount);

    // ============ 状态变量 ============
    // 合约拥有者
    address public owner;
    
    // 比特币代币(或包装代币，如WBTC)
    IERC20 public btcToken;
    
    // 用于做空永续合约的保证金代币(通常是ETH或稳定币)
    IERC20 public collateralToken;
    
    // 永续合约接口
    address public perpetualContract;
    
    // 对冲比例 (以基点表示，10000 = 100%)
    // 例如，8000 表示对冲80%的现货头寸
    uint256 public hedgeRatio = 10000;
    
    // 最小再平衡阈值 (以基点表示)
    // 当对冲头寸偏离目标对冲比例超过这个阈值时，将触发再平衡
    uint256 public rebalanceThreshold = 500; // 5%的偏差
    
    // 对冲头寸信息
    struct HedgePosition {
        uint256 spotAmount;     // 持有的BTC现货数量
        uint256 perpetualAmount; // 在永续合约上做空的BTC数量
        uint256 lastSpotPrice;  // 上次操作时的BTC/USD价格
        uint256 timestamp;      // 上次操作时间戳
    }
    
    // 当前对冲头寸
    HedgePosition public currentHedge;
    
    // 对冲策略统计
    uint256 public totalProfitTaken;
    uint256 public hedgeOperationsCount;

    // ============ 修饰符 ============
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    // ============ 构造函数 ============
    /**
     * @param _btcToken 比特币代币地址
     * @param _collateralToken 用于做空永续合约的保证金代币地址
     * @param _perpetualContract 永续合约地址
     */
    constructor(
        address _btcToken,
        address _collateralToken,
        address _perpetualContract
    ) public {
        owner = msg.sender;
        btcToken = IERC20(_btcToken);
        collateralToken = IERC20(_collateralToken);
        perpetualContract = _perpetualContract;
    }

    // ============ 公共函数 ============
    /**
     * @notice 创建新的对冲头寸
     * @param spotAmount 需要对冲的BTC现货数量
     * @param spotPrice 当前BTC/USD价格
     * @param perpetualCollateral 用于永续合约的保证金数量
     */
    function createHedgePosition(
        uint256 spotAmount,
        uint256 spotPrice,
        uint256 perpetualCollateral
    ) external onlyOwner {
        require(currentHedge.spotAmount == 0, "Hedge position already exists");
        require(spotAmount > 0, "Spot amount must be greater than 0");
        
        // 转移BTC到合约
        btcToken.safeTransferFrom(msg.sender, address(this), spotAmount);
        
        // 计算需要做空的永续合约数量（根据对冲比例）
        uint256 perpetualAmount = spotAmount.mul(hedgeRatio).div(10000);
        
        // 转移保证金到合约
        collateralToken.safeTransferFrom(msg.sender, address(this), perpetualCollateral);
        
        // 授权永续合约使用保证金
        collateralToken.approve(perpetualContract, perpetualCollateral);
        
        // 在永续合约上创建空头头寸
        // 注意：这里假设永续合约有一个openPosition函数，实际实现可能需要调整
        // solium-disable-next-line security/no-low-level-calls
        (bool success, ) = perpetualContract.call(
            abi.encodeWithSignature(
                "openPosition(bool,uint256,uint256)",
                false, // isLong = false 表示做空
                perpetualAmount,
                perpetualCollateral
            )
        );
        require(success, "Failed to open perpetual position");
        
        // 更新当前对冲状态
        currentHedge = HedgePosition({
            spotAmount: spotAmount,
            perpetualAmount: perpetualAmount,
            lastSpotPrice: spotPrice,
            timestamp: block.timestamp
        });
        
        hedgeOperationsCount++;
        
        emit HedgePositionCreated(spotAmount, perpetualAmount, spotPrice);
    }
    
    /**
     * @notice 调整对冲头寸
     * @param newSpotAmount 新的BTC现货数量
     * @param spotPrice 当前BTC/USD价格
     * @param additionalCollateral 额外的保证金数量(如果需要)
     */
    function adjustHedgePosition(
        uint256 newSpotAmount,
        uint256 spotPrice,
        uint256 additionalCollateral
    ) external onlyOwner {
        require(currentHedge.spotAmount > 0, "No hedge position exists");
        
        // 计算需要做空的新永续合约数量
        uint256 newPerpetualAmount = newSpotAmount.mul(hedgeRatio).div(10000);
        
        // 处理BTC现货变化
        if (newSpotAmount > currentHedge.spotAmount) {
            // 增加现货头寸
            uint256 additionalSpot = newSpotAmount.sub(currentHedge.spotAmount);
            btcToken.safeTransferFrom(msg.sender, address(this), additionalSpot);
        } else if (newSpotAmount < currentHedge.spotAmount) {
            // 减少现货头寸
            uint256 excessSpot = currentHedge.spotAmount.sub(newSpotAmount);
            btcToken.safeTransfer(msg.sender, excessSpot);
        }
        
        // 处理永续合约变化
        if (newPerpetualAmount != currentHedge.perpetualAmount) {
            // 如果需要额外保证金
            if (additionalCollateral > 0) {
                collateralToken.safeTransferFrom(msg.sender, address(this), additionalCollateral);
                collateralToken.approve(perpetualContract, additionalCollateral);
            }
            
            if (newPerpetualAmount > currentHedge.perpetualAmount) {
                // 增加空头头寸
                uint256 additionalPerp = newPerpetualAmount.sub(currentHedge.perpetualAmount);
                // solium-disable-next-line security/no-low-level-calls
                (bool success, ) = perpetualContract.call(
                    abi.encodeWithSignature(
                        "openPosition(bool,uint256,uint256)",
                        false, // isLong = false 表示做空
                        additionalPerp,
                        additionalCollateral
                    )
                );
                require(success, "Failed to increase perpetual position");
            } else {
                // 减少空头头寸
                uint256 excessPerp = currentHedge.perpetualAmount.sub(newPerpetualAmount);
                // solium-disable-next-line security/no-low-level-calls
                (bool success, ) = perpetualContract.call(
                    abi.encodeWithSignature(
                        "closePosition(uint256)",
                        excessPerp
                    )
                );
                require(success, "Failed to decrease perpetual position");
            }
        }
        
        // 更新当前对冲状态
        currentHedge = HedgePosition({
            spotAmount: newSpotAmount,
            perpetualAmount: newPerpetualAmount,
            lastSpotPrice: spotPrice,
            timestamp: block.timestamp
        });
        
        hedgeOperationsCount++;
        
        emit HedgePositionAdjusted(newSpotAmount, newPerpetualAmount, spotPrice);
    }
    
    /**
     * @notice 关闭对冲头寸
     * @param spotPrice 当前BTC/USD价格
     */
    function closeHedgePosition(uint256 spotPrice) external onlyOwner {
        require(currentHedge.spotAmount > 0, "No hedge position exists");
        
        // 关闭永续合约空头头寸
        // solium-disable-next-line security/no-low-level-calls
        (bool success, ) = perpetualContract.call(
            abi.encodeWithSignature(
                "closePosition(uint256)",
                currentHedge.perpetualAmount
            )
        );
        require(success, "Failed to close perpetual position");
        
        // 计算对冲的PnL
        int256 spotPnL = -int256(currentHedge.spotAmount.mul(spotPrice.sub(currentHedge.lastSpotPrice)).div(currentHedge.lastSpotPrice));
        int256 perpPnL = int256(currentHedge.perpetualAmount.mul(currentHedge.lastSpotPrice.sub(spotPrice)).div(currentHedge.lastSpotPrice));
        int256 totalPnL = spotPnL + perpPnL;
        
        // 发送BTC回给所有者
        btcToken.safeTransfer(owner, currentHedge.spotAmount);
        
        // 发送保证金代币回给所有者
        uint256 collateralBalance = collateralToken.balanceOf(address(this));
        if (collateralBalance > 0) {
            collateralToken.safeTransfer(owner, collateralBalance);
        }
        
        emit HedgePositionClosed(currentHedge.spotAmount, currentHedge.perpetualAmount, spotPrice, totalPnL);
        
        // 重置对冲状态
        currentHedge = HedgePosition({
            spotAmount: 0,
            perpetualAmount: 0,
            lastSpotPrice: 0,
            timestamp: 0
        });
        
        hedgeOperationsCount++;
    }
    
    /**
     * @notice 检查对冲头寸是否需要再平衡
     * @param currentSpotPrice 当前BTC/USD价格
     * @return 是否需要再平衡
     */
    function needsRebalancing(uint256 currentSpotPrice) public view returns (bool) {
        if (currentHedge.spotAmount == 0) {
            return false;
        }
        
        // 计算理想的对冲金额
        uint256 idealPerpetualAmount = currentHedge.spotAmount.mul(hedgeRatio).div(10000);
        
        // 计算当前的对冲偏差（考虑价格变化）
        uint256 currentPerpetualValue = currentHedge.perpetualAmount.mul(currentSpotPrice);
        uint256 idealPerpetualValue = idealPerpetualAmount.mul(currentSpotPrice);
        
        // 计算偏差百分比
        uint256 deviation;
        if (currentPerpetualValue > idealPerpetualValue) {
            deviation = currentPerpetualValue.sub(idealPerpetualValue).mul(10000).div(idealPerpetualValue);
        } else {
            deviation = idealPerpetualValue.sub(currentPerpetualValue).mul(10000).div(idealPerpetualValue);
        }
        
        // 如果偏差超过阈值，需要再平衡
        return deviation > rebalanceThreshold;
    }
    
    /**
     * @notice 计算对冲头寸的当前市场价值
     * @param currentSpotPrice 当前BTC/USD价格
     * @return 现货价值，永续合约头寸价值，总价值
     */
    function getHedgeValue(uint256 currentSpotPrice) public view returns (
        uint256 spotValue,
        int256 perpetualValue,
        int256 totalValue
    ) {
        spotValue = currentHedge.spotAmount.mul(currentSpotPrice);
        
        // 永续合约价值考虑了价格变化的盈亏（空头头寸价值与价格变化方向相反）
        int256 perpPnL;
        if (currentSpotPrice > currentHedge.lastSpotPrice) {
            // 价格上涨，空头亏损
            perpPnL = -int256(currentHedge.perpetualAmount.mul(currentSpotPrice.sub(currentHedge.lastSpotPrice)));
        } else {
            // 价格下跌，空头盈利
            perpPnL = int256(currentHedge.perpetualAmount.mul(currentHedge.lastSpotPrice.sub(currentSpotPrice)));
        }
        
        perpetualValue = -int256(currentHedge.perpetualAmount.mul(currentSpotPrice)) + perpPnL;
        totalValue = int256(spotValue) + perpetualValue;
        
        return (spotValue, perpetualValue, totalValue);
    }
    
    /**
     * @notice 添加额外的抵押品到永续合约
     * @param amount 要添加的抵押品数量
     */
    function addCollateral(uint256 amount) external onlyOwner {
        require(currentHedge.spotAmount > 0, "No hedge position exists");
        
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralToken.approve(perpetualContract, amount);
        
        // solium-disable-next-line security/no-low-level-calls
        (bool success, ) = perpetualContract.call(
            abi.encodeWithSignature(
                "addCollateral(uint256)",
                amount
            )
        );
        require(success, "Failed to add collateral");
        
        emit CollateralAdded(amount);
    }
    
    /**
     * @notice 从永续合约移除部分抵押品
     * @param amount 要移除的抵押品数量
     */
    function removeCollateral(uint256 amount) external onlyOwner {
        require(currentHedge.spotAmount > 0, "No hedge position exists");
        
        // solium-disable-next-line security/no-low-level-calls
        (bool success, ) = perpetualContract.call(
            abi.encodeWithSignature(
                "removeCollateral(uint256)",
                amount
            )
        );
        require(success, "Failed to remove collateral");
        
        collateralToken.safeTransfer(owner, amount);
        
        emit CollateralRemoved(amount);
    }
    
    /**
     * @notice 获取对冲头寸的盈利并发送给所有者
     * @param currentSpotPrice 当前BTC/USD价格
     */
    function takeProfits(uint256 currentSpotPrice) external onlyOwner {
        require(currentHedge.spotAmount > 0, "No hedge position exists");
        
        // 获取当前头寸价值
        (,, int256 totalValue) = getHedgeValue(currentSpotPrice);
        
        // 如果总价值为正，则可以提取一部分利润
        require(totalValue > 0, "No profits available to take");
        
        // 提取一半的利润
        uint256 profitToTake = uint256(totalValue).div(2);
        
        // 从永续合约中移除部分抵押品作为利润
        // solium-disable-next-line security/no-low-level-calls
        (bool success, ) = perpetualContract.call(
            abi.encodeWithSignature(
                "removeCollateral(uint256)",
                profitToTake
            )
        );
        require(success, "Failed to remove profits");
        
        // 将利润转给所有者
        collateralToken.safeTransfer(owner, profitToTake);
        
        // 更新统计数据
        totalProfitTaken = totalProfitTaken.add(profitToTake);
        
        emit ProfitTaken(profitToTake);
    }
    
    /**
     * @notice 设置对冲比例
     * @param newRatio 新的对冲比例（基点，10000 = 100%）
     */
    function setHedgeRatio(uint256 newRatio) external onlyOwner {
        require(newRatio <= 20000, "Hedge ratio cannot exceed 200%");
        hedgeRatio = newRatio;
    }
    
    /**
     * @notice 设置再平衡阈值
     * @param newThreshold 新的再平衡阈值（基点）
     */
    function setRebalanceThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold <= 2000, "Rebalance threshold cannot exceed 20%");
        rebalanceThreshold = newThreshold;
    }
    
    /**
     * @notice 紧急函数 - 允许所有者在极端情况下撤回所有资金
     */
    function emergencyWithdraw() external onlyOwner {
        // 尝试先关闭永续合约头寸
        if (currentHedge.perpetualAmount > 0) {
            // solium-disable-next-line security/no-low-level-calls
            perpetualContract.call(
                abi.encodeWithSignature(
                    "closePosition(uint256)",
                    currentHedge.perpetualAmount
                )
            );
        }
        
        // 发送所有BTC回给所有者
        uint256 btcBalance = btcToken.balanceOf(address(this));
        if (btcBalance > 0) {
            btcToken.safeTransfer(owner, btcBalance);
        }
        
        // 发送所有保证金代币回给所有者
        uint256 collateralBalance = collateralToken.balanceOf(address(this));
        if (collateralBalance > 0) {
            collateralToken.safeTransfer(owner, collateralBalance);
        }
        
        // 重置对冲状态
        currentHedge = HedgePosition({
            spotAmount: 0,
            perpetualAmount: 0,
            lastSpotPrice: 0,
            timestamp: 0
        });
    }
    
    /**
     * @notice 转移合约所有权
     * @param newOwner 新的所有者地址
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        owner = newOwner;
    }
}
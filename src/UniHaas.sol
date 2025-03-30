// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ABDKMath64x64} from "abdk-libraries-solidity/ABDKMath64x64.sol";

/**
 * @title UniHaaS
 * @notice UniHaaS is a no-code Hook-as-a-Service platform for Uniswap v4 that enables
 *         easy creation and deployment of hooks. This contract implements dynamic fees
 *         based on market volatility using Chainlink price feeds.
 * @dev Currently, only dynamic fees are implemented. Other functionalities like
 *      impermanent loss protection, MEV resistance, and limit orders will be added over time.
 */
contract UniHaas is BaseHook {
    using LPFeeLibrary for uint24;
    using ABDKMath64x64 for int128;

    // Fee adjustment parameters using sigmoid function
    int128 private immutable lowerFee;
    int128 private immutable upperFee;
    int128 private immutable steepness;
    int128 private immutable midpoint;

    // Chainlink price feeds for short-term and long-term volatility data
    AggregatorV3Interface internal shortTermVolatilityFeed;
    AggregatorV3Interface internal longTermVolatilityFeed;

    // Struct to store volatility data for each pool
    struct MarketData {
        AggregatorV3Interface shortTermFeed;
        AggregatorV3Interface longTermFeed;
        uint precision;
    }

    // Mapping of PoolId to their respective volatility data
    mapping(PoolId => MarketData) public marketVolatilityData;

    // Default fee in case market data is missing
    uint24 public constant DEFAULT_FEE = 5000;

    // Custom errors for better gas efficiency
    error DynamicFeeRequired();
    error FeeBoundsInvalid();

    /**
     * @notice Constructor initializes the dynamic fee parameters and Chainlink data feeds.
     * @param _manager The Uniswap v4 PoolManager contract address.
     * @param _shortTermFeed Chainlink price feed address for short-term volatility.
     * @param _longTermFeed Chainlink price feed address for long-term volatility.
     * @param _minFee Minimum allowable fee (scaled).
     * @param _maxFee Maximum allowable fee (scaled).
     * @param _alpha Steepness parameter for the sigmoid function.
     * @param _beta Midpoint parameter for the sigmoid function.
     */
    constructor(
        IPoolManager _manager,
        address _shortTermFeed,
        address _longTermFeed,
        int256 _minFee,
        int256 _maxFee,
        int128 _alpha,
        int128 _beta
    ) BaseHook(_manager) {
        shortTermVolatilityFeed = AggregatorV3Interface(_shortTermFeed);
        longTermVolatilityFeed = AggregatorV3Interface(_longTermFeed);

        if (_minFee >= _maxFee) revert FeeBoundsInvalid();

        lowerFee = ABDKMath64x64.fromInt(_minFee);
        upperFee = ABDKMath64x64.fromInt(_maxFee);
        steepness = _alpha == 0 ? ABDKMath64x64.fromUInt(5) : _alpha;
        midpoint = _beta == 0 ? ABDKMath64x64.fromUInt(3) : _beta;
    }

    /**
     * @notice Defines which Uniswap v4 Hook permissions this contract uses.
     * @return Hooks.Permissions object specifying allowed actions.
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /**
     * @notice Ensures that only pools with dynamic fees are initialized.
     */
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert DynamicFeeRequired();
        return this.beforeInitialize.selector;
    }

    /**
     * @notice Adjusts the swap fee dynamically based on market conditions.
     */
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = computeFee(key.toId());
        uint24 adjustedFee = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            adjustedFee
        );
    }

    /**
     * @notice Computes the dynamic fee for a given pool based on market volatility.
     */
    function computeFee(PoolId poolId) public view returns (uint24) {
        if (address(marketVolatilityData[poolId].shortTermFeed) == address(0)) {
            return DEFAULT_FEE;
        }

        MarketData memory data = marketVolatilityData[poolId];
        int shortVol = fetchLatestData(data.shortTermFeed);
        int longVol = fetchLatestData(data.longTermFeed);

        return determineDynamicFee(longVol, shortVol);
    }

    /**
     * @notice Fetches the latest volatility data from a Chainlink feed.
     */
    function fetchLatestData(
        AggregatorV3Interface _feed
    ) public view returns (int) {
        (, int answer, , , ) = _feed.latestRoundData();
        return answer;
    }

    /**
     * @notice Updates market volatility data for a specific pool.
     */
    function updateMarketData(
        PoolKey calldata _key,
        address _shortFeed,
        address _longFeed,
        uint8 _precision
    ) external {
        marketVolatilityData[_key.toId()] = MarketData({
            shortTermFeed: AggregatorV3Interface(_shortFeed),
            longTermFeed: AggregatorV3Interface(_longFeed),
            precision: _precision
        });
    }

    /**
     * @notice Removes market volatility data for a specific pool.
     */
    function removeMarketData(PoolKey calldata key) external {
        require(
            address(marketVolatilityData[key.toId()].shortTermFeed) !=
                address(0),
            "Market data missing"
        );
        delete marketVolatilityData[key.toId()];
    }

    /**
     * @notice Computes the dynamic fee using a sigmoid function based on volatility.
     */
    function sigmoidFeeCalculation(
        int256 volatility,
        int128 alpha,
        int128 beta
    ) public view returns (uint24) {
        if (volatility > 2000000) return uint24(ABDKMath64x64.toUInt(upperFee));
        if (volatility == 0) return uint24(ABDKMath64x64.toUInt(lowerFee));

        int128 volFixed = ABDKMath64x64.fromInt(volatility);
        int128 adjustedVol = volFixed.div(ABDKMath64x64.fromUInt(10 ** 5)).sub(
            beta
        );
        int128 sigmoidValue = ABDKMath64x64.div(
            ABDKMath64x64.fromInt(1),
            ABDKMath64x64.fromInt(1).add(
                ABDKMath64x64.exp(steepness.mul(adjustedVol).neg())
            )
        );

        return
            uint24(
                ABDKMath64x64.toUInt(
                    lowerFee.add((upperFee.sub(lowerFee)).mul(sigmoidValue))
                )
            );
    }

    /**
     * @notice Determines the appropriate fee based on short-term and long-term volatility trends.
     */
    function determineDynamicFee(
        int256 vol7d,
        int256 vol24h
    ) public view returns (uint24) {
        return sigmoidFeeCalculation(vol24h, steepness, midpoint);
    }
}

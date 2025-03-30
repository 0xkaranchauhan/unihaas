// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {UniHaas} from "../src/UniHaas.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/**
 * @title TestUniHaas
 * @notice Test contract for UniHaaS, a no-code Uniswap V4 Hook-as-a-Service platform
 *         that simplifies hook development. UniHaaS aims to provide modular,
 *         plug-and-play hooks for various DeFi functionalities.
 * @dev Currently, we have implemented dynamic fees based on market volatility
 *      using Chainlink price feeds. Additional features like impermanent loss
 *      protection, MEV resistance, and limit orders will be added progressively.
 *      Built using Foundry's testing framework and Uniswap V4's Deployers utility.
 */

contract TestUniHaas is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Main contract instances
    UniHaas hook;
    MockV3Aggregator public mockV3Aggregator24H;
    MockV3Aggregator public mockV3Aggregator7D;

    // Configuration constants for volatility feeds
    uint8 public constant DECIMALS = 5;
    int256 public constant INITIAL_ANSWER_24H = 4 * int(10 ** DECIMALS); // 4%
    int256 public constant INITIAL_ANSWER_7D = 1 * int(10 ** DECIMALS); // 10%

    // Fee calculation parameters
    uint24 public constant MIN_FEE = 3000; // Minimum fee in bps (0.3%)
    uint24 public constant MAX_FEE = 10000; // Maximum fee in bps (1%)
    int128 public constant ALPHA = 2; // Steepness parameter for sigmoid function
    int128 public constant BETA = 5; // Midpoint parameter for sigmoid function

    /**
     * @notice Sets up the test environment
     * @dev Deploys mock oracle feeds, Uniswap V4 contracts, and initializes the hook with test parameters
     */
    function setUp() public {
        // Deploy mock Chainlink aggregators with initial volatility values
        mockV3Aggregator24H = new MockV3Aggregator(
            DECIMALS,
            INITIAL_ANSWER_24H
        );
        mockV3Aggregator7D = new MockV3Aggregator(DECIMALS, INITIAL_ANSWER_7D);

        // Deploy Uniswap V4 core contracts (manager and routers)
        deployFreshManagerAndRouters();

        // Deploy test tokens and approve them for use with periphery contracts
        deployMintAndApprove2Currencies();

        // Calculate hook address with appropriate hook flags
        // Using BEFORE_INITIALIZE_FLAG to set up volatility data
        // Using BEFORE_SWAP_FLAG to calculate dynamic fees on each swap
        address hookAddress = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)
        );

        // Set gas price for deployment transaction
        vm.txGasPrice(10 gwei);

        // Deploy the UniHaas hook with test configuration
        deployCodeTo(
            "UniHaas",
            abi.encode(
                manager,
                mockV3Aggregator24H,
                mockV3Aggregator7D,
                MIN_FEE,
                MAX_FEE,
                ALPHA,
                BETA
            ),
            hookAddress
        );
        hook = UniHaas(hookAddress);

        // Initialize a Uniswap V4 pool with our hook and dynamic fee flag
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Enable dynamic fees rather than fixed fee
            SQRT_PRICE_1_1
        );

        // Configure market data sources for the pool
        hook.updateMarketData(
            key,
            address(mockV3Aggregator24H),
            address(mockV3Aggregator7D),
            DECIMALS
        );

        // Add initial liquidity to the pool for testing swaps
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /**
     * @notice Verifies that volatility data is correctly fetched from Chainlink oracles
     * @dev Compares the data returned by the hook with expected initial values
     */
    function testVerifyVolatilitySource() public view {
        // Fetch current volatility metrics from data feeds
        int256 volatility24H = hook.fetchLatestData(
            AggregatorV3Interface(address(mockV3Aggregator24H))
        );
        int256 volatility7D = hook.fetchLatestData(
            AggregatorV3Interface(address(mockV3Aggregator7D))
        );

        // Verify the fetched values match our expected initial values
        assertEq(
            volatility24H,
            INITIAL_ANSWER_24H,
            "24H volatility doesn't match expected value"
        );
        assertEq(
            volatility7D,
            INITIAL_ANSWER_7D,
            "7D volatility doesn't match expected value"
        );
    }

    /**
     * @notice Tests the fee calculation logic with the default volatility setting
     * @dev Logs the calculated fee value for verification
     */
    function testCalculateFeeValue() public {
        // Ensure the 24H volatility is set to our initial test value
        mockV3Aggregator24H.updateAnswer(INITIAL_ANSWER_24H);

        // Compute the fee for our test pool
        uint24 value = hook.computeFee(key.toId());

        // Log the calculated fee for manual verification
        console.log("get fee:", value);
    }

    /**
     * @notice Tests that fees remain within configured boundaries regardless of volatility
     * @dev Checks both minimum and maximum fee boundaries
     */
    function testFeeMinMaxBoundaries() public {
        // Test minimum fee boundary (zero volatility)
        mockV3Aggregator24H.updateAnswer(0);
        uint24 minFeeCase = hook.computeFee(key.toId());
        assertEq(
            minFeeCase,
            MIN_FEE,
            "Fee should be at minimum when volatility is 0"
        );

        // Test maximum fee boundary (extremely high volatility)
        mockV3Aggregator24H.updateAnswer(int256(100) * int256(10 ** DECIMALS)); // 100% volatility
        uint24 maxFeeCase = hook.computeFee(key.toId());
        assertEq(
            maxFeeCase,
            MAX_FEE,
            "Fee should be at maximum when volatility is very high"
        );
    }

    /**
     * @notice Tests the relationship between market volatility and calculated fees
     * @dev Verifies that fees increase monotonically with increased volatility
     */
    function testVolatilityFeeCorrelation() public {
        // Define a series of increasing volatility test points
        int256[] memory volatilities = new int256[](4);
        volatilities[0] = int256(1) * int256(10 ** DECIMALS); // 1% volatility
        volatilities[1] = int256(5) * int256(10 ** DECIMALS); // 5% volatility
        volatilities[2] = int256(10) * int256(10 ** DECIMALS); // 10% volatility
        volatilities[3] = int256(20) * int256(10 ** DECIMALS); // 20% volatility

        uint24[] memory fees = new uint24[](4);

        // Test fee calculation for each volatility level
        for (uint i = 0; i < volatilities.length; i++) {
            mockV3Aggregator24H.updateAnswer(volatilities[i]);
            fees[i] = hook.computeFee(key.toId());

            // Verify fees increase with volatility (except for first element)
            if (i > 0) {
                assertTrue(
                    fees[i] >= fees[i - 1],
                    "Fees should increase with volatility"
                );
            }
        }
    }

    /**
     * @notice Tests that pool initialization fails when data feeds are not configured
     * @dev Expects a revert when trying to initialize without setting market data
     */
    function testPoolInitWithoutDataFeed() public {
        // Create a new pool key without configuring data feeds
        PoolKey memory newKey = PoolKey({
            currency0: Currency(currency0),
            currency1: Currency(currency1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Attempt to initialize should fail due to missing data feed configuration
        vm.expectRevert(); // Should revert if trying to initialize without setting data feed
        manager.initialize(newKey, SQRT_PRICE_1_1);
    }

    /**
     * @notice Tests the ability to update data sources for volatility feeds
     * @dev Verifies that new data feeds are correctly used after update
     */
    function testMarketDataUpdate() public {
        // Deploy new mock aggregators for testing update functionality
        MockV3Aggregator newAggregator24H = new MockV3Aggregator(
            DECIMALS,
            INITIAL_ANSWER_24H
        );
        MockV3Aggregator newAggregator7D = new MockV3Aggregator(
            DECIMALS,
            INITIAL_ANSWER_7D
        );

        // Update the pool's data feed sources
        hook.updateMarketData(
            key,
            address(newAggregator24H),
            address(newAggregator7D),
            DECIMALS
        );

        // Set a new volatility value on the updated feed
        newAggregator24H.updateAnswer(int256(5) * int256(10 ** DECIMALS)); // 5%

        // Verify the fee calculation uses the new data source
        uint24 newFee = hook.computeFee(key.toId());
        assertTrue(newFee != 0, "Fee should be calculated with new feed");
    }

    /**
     * @notice Tests a complete swap execution with dynamic fees
     * @dev Ensures swaps work correctly with dynamically calculated fees
     */
    function testDynamicFeeSwapExecution() public {
        // Set test volatility for the swap
        mockV3Aggregator24H.updateAnswer(int256(5) * int256(10 ** DECIMALS)); // 5%

        // Configure swap parameters
        bool zeroForOne = true; // Swap token0 for token1
        int256 amountSpecified = 1e18; // Swap 1 unit of token

        // Create swap parameters
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        // Configure test settings
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: true, settleUsingBurn: false});

        // Execute the swap using the router (handles locking internally)
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        // No assertion needed - test passes if swap doesn't revert
    }

    /**
     * @notice Tests validation of fee boundary configuration
     * @dev Ensures the contract rejects invalid fee boundaries (min > max)
     */
    function testInvalidFeeBoundConfiguration() public {
        // Calculate hook address with required hook flags
        address hookAddress = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)
        );

        // Attempt to deploy with invalid fee configuration (min > max)
        vm.expectRevert(); // Should revert on invalid fee bounds
        deployCodeTo(
            "UniHaas",
            abi.encode(
                manager,
                mockV3Aggregator24H,
                mockV3Aggregator7D,
                MAX_FEE, // Using max as min (invalid)
                MIN_FEE, // Using min as max (invalid)
                ALPHA,
                BETA
            ),
            hookAddress
        );
    }
}

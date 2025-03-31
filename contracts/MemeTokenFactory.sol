    
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol"; // For min function
import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; // Prevent re-entrancy attacks on swaps
import "./MemeToken.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MemeTokenFactory is Ownable, ReentrancyGuard {
    address public immutable uniswapV2RouterAddress;
    address public immutable uniswapV2FactoryAddress;
    address public immutable WETHAddress;

    // --- Virtual Pool Data Structure ---
    struct VirtualPool {
        uint256 tokenReserve;       // Tokens held by THIS factory for the pool
        uint256 ethReserve;         // ETH held by THIS factory for the pool
        bool realLiquidityAdded;    // Flag: true if migrated to Uniswap
        bool initialized;           // Flag: true if pool exists and is funded
        uint256 kLast;              // Optional: For k=x*y consistency checks
    }

    mapping(address => VirtualPool) public virtualPools; // Token address => Pool data
    mapping(address => address) public tokenCreator; // Token address => Creator address

    // --- Events ---
    event TokenCreated(
        address indexed tokenAddress,
        address indexed creator,
        string name,
        string symbol
    );

    event VirtualPoolInitialized(
        address indexed tokenAddress,
        uint256 initialTokenReserve,
        uint256 initialEthReserve
    );

    event VirtualSwap(
        address indexed tokenAddress,
        address indexed swapper,
        uint256 amountEthIn,
        uint256 amountTokenIn,
        uint256 amountEthOut,
        uint256 amountTokenOut
    );

    event RealLiquidityAdded(
        address indexed tokenAddress,
        address indexed pairAddress,
        uint256 tokenAmount,
        uint256 ethAmount
    );

    // Fee for virtual swaps (e.g., 0.3% = 30 basis points)
    uint256 public constant VIRTUAL_SWAP_FEE_BPS = 30; // Basis points (30 / 10000)
    uint256 public constant FEE_DENOMINATOR = 10000;

    // --- Constructor ---
    constructor(address _uniswapV2Router, address _wethAddress) Ownable(msg.sender) {
        require(_uniswapV2Router != address(0) && _wethAddress != address(0), "Factory: Zero Address");
        uniswapV2RouterAddress = _uniswapV2Router;
        WETHAddress = _wethAddress;
        try IUniswapV2Router02(_uniswapV2Router).factory() returns (address _factory) {
            require(_factory != address(0), "Factory: Invalid Router Factory");
            uniswapV2FactoryAddress = _factory;
        } catch {
            revert("Factory: Invalid Router Address");
        }
    }

    // --- Step 1: Create Token Contract ---
    function createToken(
        string memory name,
        string memory symbol
    ) external returns (address tokenAddress) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, "Factory: Invalid Name/Symbol");

        // Deploy the token, factory is the initial owner
        MemeToken newToken = new MemeToken(name, symbol, address(this));
        tokenAddress = address(newToken);
        tokenCreator[tokenAddress] = msg.sender; // Store who requested the token creation

        emit TokenCreated(tokenAddress, msg.sender, name, symbol);
        return tokenAddress;
    }

    // --- Step 2: Initialize the Virtual Pool ---
    /**
     * @notice Owner funds the virtual pool with initial tokens and ETH.
     * @param tokenAddress The address of the MemeToken created earlier.
     * @param totalTokenSupply The total supply to mint for the token.
     * @param tokenAmountForPool The amount of tokens (with decimals) for the virtual pool.
     * @param creatorAllocation Amount (with decimals) to send to the token creator.
     * @dev Must send ETH (msg.value) for the initial ETH reserve.
     * @dev Only the factory owner can call this.
     */
    function initializeVirtualPool(
        address tokenAddress,
        uint256 totalTokenSupply,    // Total supply (with decimals)
        uint256 tokenAmountForPool,  // For virtual pool (with decimals)
        uint256 creatorAllocation    // For creator (with decimals)
    ) external payable onlyOwner {
        require(tokenAddress != address(0), "Factory: Invalid token address");
        MemeToken token = MemeToken(tokenAddress);
        // Ensure the caller of createToken matches if needed, or rely on onlyOwner
        // require(tokenCreator[tokenAddress] != address(0), "Factory: Token not created by factory");

        VirtualPool storage pool = virtualPools[tokenAddress];
        require(!pool.initialized, "Factory: Pool already initialized");
        require(msg.value > 0, "Factory: Initial ETH required");
        require(tokenAmountForPool > 0, "Factory: Initial tokens required");
        require(totalTokenSupply >= tokenAmountForPool + creatorAllocation, "Factory: Supply calculation error");

        // 1. Mint the total supply
        token.mint(address(this), totalTokenSupply); // Mint all to factory first

        // 2. Allocate tokens
        uint256 factoryKeeps = totalTokenSupply - creatorAllocation;
        require(factoryKeeps >= tokenAmountForPool, "Factory: Not enough tokens for pool after allocation");

        if (creatorAllocation > 0) {
            address creator = tokenCreator[tokenAddress];
            require(creator != address(0), "Factory: Creator not found");
            require(token.transfer(creator, creatorAllocation), "Factory: Creator transfer failed");
        }
        // The factory now holds `factoryKeeps` tokens. `tokenAmountForPool` of these are designated for the pool.

        // 3. Initialize pool state
        pool.tokenReserve = tokenAmountForPool;
        pool.ethReserve = msg.value;
        pool.initialized = true;
        pool.realLiquidityAdded = false;
        pool.kLast = pool.tokenReserve * pool.ethReserve; // Initialize k

        emit VirtualPoolInitialized(tokenAddress, pool.tokenReserve, pool.ethReserve);
    }


    // --- Step 3: Virtual Swaps (Before Real Liquidity) ---

    // Internal function to calculate swap output based on reserves
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "Factory: Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Factory: Insufficient liquidity");
        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - VIRTUAL_SWAP_FEE_BPS); // amountIn * 9970
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * FEE_DENOMINATOR) + amountInWithFee; // reserveIn * 10000 + amountIn * 9970
        amountOut = numerator / denominator;
    }

     // Buy Token using ETH in the virtual pool
    function swapEthForToken(address tokenAddress) external payable nonReentrant {
        VirtualPool storage pool = virtualPools[tokenAddress];
        require(pool.initialized, "Factory: Pool not initialized");
        require(!pool.realLiquidityAdded, "Factory: Use Uniswap");
        require(msg.value > 0, "Factory: Must send ETH");

        IERC20 token = IERC20(tokenAddress);
        uint256 ethIn = msg.value;
        uint256 tokenReserve = pool.tokenReserve;
        uint256 ethReserve = pool.ethReserve; // Before adding ethIn

        uint256 tokensOut = getAmountOut(ethIn, ethReserve, tokenReserve);
        require(tokensOut > 0 && tokensOut <= tokenReserve, "Factory: Insufficient token liquidity or invalid amount");
        require(token.balanceOf(address(this)) >= tokensOut, "Factory: Factory internal token balance mismatch"); // Sanity check

        // Update reserves
        pool.ethReserve = ethReserve + ethIn;
        pool.tokenReserve = tokenReserve - tokensOut;
        pool.kLast = pool.tokenReserve * pool.ethReserve; // Update k

        // Transfer tokens to user
        require(token.transfer(msg.sender, tokensOut), "Factory: Token transfer failed");

        emit VirtualSwap(tokenAddress, msg.sender, ethIn, 0, 0, tokensOut);
    }

    // Sell Token for ETH from the virtual pool
    function swapTokenForEth(address tokenAddress, uint256 tokensIn) external nonReentrant {
        require(tokensIn > 0, "Factory: Must swap positive tokens");
        VirtualPool storage pool = virtualPools[tokenAddress];
        require(pool.initialized, "Factory: Pool not initialized");
        require(!pool.realLiquidityAdded, "Factory: Use Uniswap");

        IERC20 token = IERC20(tokenAddress);
        uint256 tokenReserve = pool.tokenReserve; // Before adding tokensIn
        uint256 ethReserve = pool.ethReserve;

        // Calculate ETH out
        uint256 ethOut = getAmountOut(tokensIn, tokenReserve, ethReserve);
        require(ethOut > 0 && ethOut <= ethReserve, "Factory: Insufficient ETH liquidity or invalid amount");
        require(address(this).balance >= ethOut, "Factory: Factory internal ETH balance mismatch"); // Sanity check

        // Transfer tokens from user to factory
        // User must have approved the factory contract beforehand
        require(token.transferFrom(msg.sender, address(this), tokensIn), "Factory: Token transferFrom failed");

        // Update reserves AFTER successful token transfer
        pool.tokenReserve = tokenReserve + tokensIn;
        pool.ethReserve = ethReserve - ethOut;
         pool.kLast = pool.tokenReserve * pool.ethReserve; // Update k

        // Transfer ETH to user
        (bool success, ) = msg.sender.call{value: ethOut}("");
        require(success, "Factory: ETH transfer failed");

        emit VirtualSwap(tokenAddress, msg.sender, 0, tokensIn, ethOut, 0);
    }

     // --- Step 4: Transition to Real Uniswap Liquidity ---
    /**
     * @notice Moves the liquidity from the virtual pool to a real Uniswap V2 pair.
     * @dev Can only be called by the owner (or adapt trigger logic).
     * @param tokenAddress The token to add liquidity for.
     * @param deadline Transaction deadline timestamp.
     */
    function addRealLiquidityToUniswap(address tokenAddress, uint256 deadline) external onlyOwner nonReentrant {
        VirtualPool storage pool = virtualPools[tokenAddress];
        require(pool.initialized, "Factory: Pool not initialized");
        require(!pool.realLiquidityAdded, "Factory: Liquidity already added");

        uint256 tokenAmount = pool.tokenReserve;
        uint256 ethAmount = pool.ethReserve;
        require(tokenAmount > 0 && ethAmount > 0, "Factory: Zero reserves cannot add liquidity");

        // Check actual balances as a safeguard
        IERC20 token = IERC20(tokenAddress);
        require(token.balanceOf(address(this)) >= tokenAmount, "Factory: Mismatch in factory token balance");
        require(address(this).balance >= ethAmount, "Factory: Mismatch in factory ETH balance");

        // 1. Mark as added BEFORE external call
        pool.realLiquidityAdded = true;
        pool.tokenReserve = 0; // Clear virtual reserves
        pool.ethReserve = 0;

        // 2. Approve Uniswap Router
        token.approve(uniswapV2RouterAddress, tokenAmount);

        // 3. Add liquidity to Uniswap
        // Use the *exact* amounts from the virtual pool. Min amounts set to 0 as we are the sole initial LP.
        (uint actualTokenAmount, uint actualEthAmount, uint liquidity) = IUniswapV2Router02(uniswapV2RouterAddress).addLiquidityETH{value: ethAmount}(
            tokenAddress,
            tokenAmount,
            0, // amountTokenMin
            0, // amountETHMin
            owner(),    // Send LP tokens to the factory owner (deployer) - or choose another address like burn
            deadline
        );

        address pairAddress = IUniswapV2Factory(uniswapV2FactoryAddress).getPair(tokenAddress, WETHAddress);

        emit RealLiquidityAdded(tokenAddress, pairAddress, actualTokenAmount, actualEthAmount);

        // Optional: Transfer any remaining dust tokens/ETH in the factory? (Shouldn't be much if logic is correct)
    }

    // --- Helper/View Functions ---
    function getVirtualPoolReserves(address tokenAddress) external view returns (uint256 tokenRes, uint256 ethRes, bool isReal) {
        VirtualPool storage pool = virtualPools[tokenAddress];
        return (pool.tokenReserve, pool.ethReserve, pool.realLiquidityAdded);
    }

    // Function to query expected swap output without executing
     function getVirtualEthToTokenOutput(address tokenAddress, uint256 ethIn) external view returns (uint256 tokensOut) {
        VirtualPool storage pool = virtualPools[tokenAddress];
        require(pool.initialized && !pool.realLiquidityAdded, "Factory: Invalid pool state");
        return getAmountOut(ethIn, pool.ethReserve, pool.tokenReserve);
    }

    function getVirtualTokenToEthOutput(address tokenAddress, uint256 tokensIn) external view returns (uint256 ethOut) {
         VirtualPool storage pool = virtualPools[tokenAddress];
         require(pool.initialized && !pool.realLiquidityAdded, "Factory: Invalid pool state");
         return getAmountOut(tokensIn, pool.tokenReserve, pool.ethReserve);
    }


    // --- Receive ETH ---
    receive() external payable {} // Needed to receive ETH for swaps and initial liquidity
}
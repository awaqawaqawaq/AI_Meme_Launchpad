// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./HotspotToken.sol";


contract TokenFactory is Ownable {
    struct TokenInfo {
        address tokenAddress;
        string tokenName;
        uint256 totalHolding;
    }

    TokenInfo[] public tokens;
    uint256 public constant COMPETITION_DURATION = 2 hours;
    uint256 public constant DEX_THRESHOLD = 1000000 ether;
    uint256 public lastCompetitionEndTime;
    // mapping(address => uint256) public ethCollected;

    event NewTokenCreated(address indexed token, string name, string symbol);
    event TokenDestroyed(address indexed token);
    // event TokenValueTransferred(address indexed fromToken, address indexed toToken, uint256 amount);
    event AutoCompensated(address indexed user, address indexed newToken, uint256 amount);
    // event LiquidityAdded(address indexed token, uint256 ethAmount, uint256 tokenAmount);

    constructor()Ownable(msg.sender)  {
        lastCompetitionEndTime = block.timestamp;
    }

    function createNewToken(string memory name, string memory symbol, uint256 initialSupply) public onlyOwner {
        require(tokens.length < 10, "Only 10 tokens can compete at once");
        HotspotToken newToken = new HotspotToken(name, symbol, initialSupply);
        tokens.push(TokenInfo(address(newToken), name,initialSupply));
        emit NewTokenCreated(address(newToken), name, symbol);
        
        // 立即加入流动性池
        // addLiquidityToWinner(address(newToken), initialSupply / 2);
    }

    function executeCompetitionRound() public onlyOwner {
        // require(block.timestamp >= lastCompetitionEndTime + COMPETITION_DURATION, "Competition not ended yet");
        require(tokens.length > 1, "Not enough tokens to compete");

        uint256 minSupply = type(uint256).max;
        uint256 maxSupply = 0;
        uint256 minIndex;
        uint256 maxIndex;

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 supply = ERC20(tokens[i].tokenAddress).totalSupply();
            if (supply < minSupply) {
                minSupply = supply;
                minIndex = i;
            }
            if (supply > maxSupply) {
                maxSupply = supply;
                maxIndex = i;
            }
        }

        address losingToken = tokens[minIndex].tokenAddress;
        address winningToken = tokens[maxIndex].tokenAddress;
        //  uint256 losingEth = ethCollected[losingToken];

        uint256 losingTokenSupply = ERC20(losingToken).totalSupply();
        // ERC20Burnable(losingToken).burn(losingTokenSupply);
        //  ethCollected[losingToken] = 0;
        emit TokenDestroyed(losingToken);

        //  uint256 winningAllocation = (losingEth * 80) / 100;
        // addLiquidityToWinner(winningToken, winningAllocation);
        //  emit TokenValueTransferred(losingToken, winningToken, winningAllocation);

    
        // 自动补偿给 `losingToken` 的持有者
        // address[] memory holders = getTokenHolders(losingToken);
        // for (uint256 i = 0; i < holders.length; i++) {
        //     uint256 userBalance = ERC20(losingToken).balanceOf(holders[i]);
        //     if (userBalance > 0) {
        //         uint256 compensationAmount = (userBalance * winningAllocation) / losingTokenSupply;
        //         ERC20(winningToken)._mint(holders[i], compensationAmount);
        //         emit AutoCompensated(holders[i], winningToken, compensationAmount);
        //     }
        // }

        tokens[minIndex] = tokens[tokens.length - 1];
        tokens.pop();
    }


    function getTokenHolders(address token) internal view returns (address[] memory) {
        // 这个方法需要 off-chain 计算或 event 索引，
        // 这里留一个接口，实际应用可以通过 TheGraph 或其他数据索引方式获取。
        address[] memory holders;
        return holders;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MemeToken is ERC20, Ownable {
    constructor(
        string memory name,
        string memory symbol,
        address initialOwner // The factory contract will be the initial owner
    ) ERC20(name, symbol) Ownable(initialOwner) {
        // Supply will be minted later by the owner (factory)
    }

    // Allow the owner (factory) to mint tokens as needed
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    // Optional: Allow owner to burn tokens if needed
    function burn(uint256 amount) public onlyOwner {
         _burn(msg.sender, amount); // Or burn from a specific address
    }
}
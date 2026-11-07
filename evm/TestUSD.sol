// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// A test dollar for the Ratify demo on GenLayer Chain. Anyone may mint up to 1,000 at a time to themselves,
/// so a visitor can open and fund a job without asking anybody. It is worth nothing.
contract TestUSD {
    string public constant name = "Ratify Test Dollar";
    string public constant symbol = "tUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(uint256 value) external {
        require(value <= 1000 * 1e18, "at most 1000 at a time");
        totalSupply += value;
        balanceOf[msg.sender] += value;
        emit Transfer(address(0), msg.sender, value);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) private {
        require(balanceOf[from] >= value, "balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}

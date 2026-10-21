// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title Mutually Assured Destruction (MAD)
/// @notice A fixed-supply ERC-20 with 18 decimals and no administrative powers.
contract MADToken is IERC20 {
    string public constant override name = "Mutually Assured Destruction";
    string public constant override symbol = "MAD";
    uint8 public constant override decimals = 18;

    /// @notice One billion MAD, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Supply is constant: there is no mint or burn entry point after construction.
    uint256 public constant override totalSupply = INITIAL_SUPPLY;
    mapping(address account => uint256 balance) public override balanceOf;
    mapping(address owner => mapping(address spender => uint256 value)) public override allowance;

    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);

    /// @notice Mints the entire supply once to the immediate deployer (the factory at launch).
    constructor() {
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Transfers exactly `value` units, including zero-value and self transfers.
    function transfer(address to, uint256 value) external override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Replaces the caller's allowance for `spender` with `value`.
    /// @dev The maximum uint256 value is an unlimited allowance. Zero revokes an allowance.
    function approve(address spender, uint256 value) external override returns (bool) {
        if (msg.sender == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @notice Transfers from `from` using the caller's allowance; finite allowances decrease.
    /// @dev Even `from` must have an allowance when using this function. Use `transfer` otherwise.
    /// Spending an allowance emits Transfer; Approval is emitted by explicit approvals only.
    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        uint256 available = allowance[from][msg.sender];
        if (available != type(uint256).max) {
            if (available < value) revert ERC20InsufficientAllowance(msg.sender, available, value);
            allowance[from][msg.sender] = available - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 available = balanceOf[from];
        if (available < value) revert ERC20InsufficientBalance(from, available, value);

        balanceOf[from] = available - value;
        // Read the destination after debiting the source so self transfers preserve the balance.
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}

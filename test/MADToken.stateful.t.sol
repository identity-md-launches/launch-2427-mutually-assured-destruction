// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MADToken} from "../src/MADToken.sol";
import {TestBase} from "./utils/TestBase.sol";

/// @dev A contract holder with no way to move tokens on its own; the handler pranks it like any actor.
contract InertHolder {
    fallback() external {
        revert("no callbacks");
    }
}

/// @dev Drives every external entry point with valid and invalid inputs: amounts above the balance or
/// the allowance, the zero address as sender, receiver, approver or spender, the token contract itself
/// as a holder, and every aliasing of owner, spender and recipient. Each call goes through a low-level
/// call so that an expected revert never aborts the sequence; the revert data is checked exactly against
/// the error the ERC-20 rules predict (allowance first, then sender, receiver and balance).
contract MADStatefulHandler is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant HOLDERS = 6;

    MADToken internal immutable token;
    address[HOLDERS] public holders;

    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    /// @dev Ghosts that let the test prove both the success and the failure paths were exercised.
    uint256 public successes;
    uint256 public expectedReverts;
    uint256 public zeroAddressAttempts;
    uint256 public overspendAttempts;
    uint256 public unlimitedSpends;
    /// @dev Units moved by successful transferFrom calls, against units the owners ever approved
    /// (an unlimited approval counts as the full supply, which is all that exists to spend).
    uint256 public totalSpentViaAllowance;
    uint256 public totalFiniteSpentViaAllowance;
    uint256 public totalFiniteApproved;

    constructor(MADToken token_, address inert) {
        token = token_;
        for (uint256 i; i < 4; ++i) {
            holders[i] = address(uint160(uint256(keccak256(abi.encode("MAD stateful holder", i)))));
        }
        holders[4] = address(token_);
        holders[5] = inert;
        expectedBalance[holders[0]] = SUPPLY;
    }

    function _pick(uint256 seed) internal view returns (address) {
        return holders[seed % HOLDERS];
    }

    function _record(bool ok, bytes memory ret, bytes memory expectedError) internal {
        if (expectedError.length == 0) {
            require(ok, "unexpected revert");
            require(ret.length == 32 && abi.decode(ret, (bool)), "did not return true");
            ++successes;
        } else {
            require(!ok, "expected revert succeeded");
            require(keccak256(ret) == keccak256(expectedError), "wrong revert reason");
            ++expectedReverts;
        }
    }

    /// @param mode 0-5 valid amount, 6-7 one unit or more above the balance, 8 to the zero address,
    /// 9 from the zero address.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount, uint8 mode) external {
        mode = mode % 10;
        address from = mode == 9 ? address(0) : _pick(fromSeed);
        address to = mode == 8 ? address(0) : _pick(toSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount;
        if (mode < 6) {
            amount = rawAmount % (balance + 1);
        } else if (mode < 8) {
            amount = balance + 1 + rawAmount % (type(uint256).max - balance);
            ++overspendAttempts;
        } else {
            amount = rawAmount % (SUPPLY + 1);
            ++zeroAddressAttempts;
        }

        bytes memory expectedError;
        if (from == address(0)) {
            expectedError = abi.encodeWithSelector(MADToken.ERC20InvalidSender.selector, address(0));
        } else if (to == address(0)) {
            expectedError = abi.encodeWithSelector(MADToken.ERC20InvalidReceiver.selector, address(0));
        } else if (amount > balance) {
            expectedError = abi.encodeWithSelector(MADToken.ERC20InsufficientBalance.selector, from, balance, amount);
        }

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(MADToken.transfer, (to, amount)));
        _record(ok, ret, expectedError);
        if (ok && from != to) {
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
    }

    /// @param mode 0 revoke, 1 unlimited, 2 type(uint256).max - 1, 3 zero spender, 4 zero approver,
    /// otherwise a finite amount up to twice the supply.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount, uint8 mode) external {
        mode = mode % 8;
        address owner = mode == 4 ? address(0) : _pick(ownerSeed);
        address spender = mode == 3 ? address(0) : _pick(spenderSeed);
        uint256 amount = mode == 0
            ? 0
            : mode == 1 ? type(uint256).max : mode == 2 ? type(uint256).max - 1 : rawAmount % (2 * SUPPLY + 1);
        if (owner == address(0) || spender == address(0)) ++zeroAddressAttempts;

        bytes memory expectedError;
        if (owner == address(0)) {
            expectedError = abi.encodeWithSelector(MADToken.ERC20InvalidApprover.selector, address(0));
        } else if (spender == address(0)) {
            expectedError = abi.encodeWithSelector(MADToken.ERC20InvalidSpender.selector, address(0));
        }

        vm.prank(owner);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(MADToken.approve, (spender, amount)));
        _record(ok, ret, expectedError);
        if (ok) {
            expectedAllowance[owner][spender] = amount;
            if (amount != type(uint256).max) {
                // Saturating: grants of nearly 2**256 would otherwise overflow the running sum.
                uint256 room = type(uint256).max - totalFiniteApproved;
                totalFiniteApproved += amount < room ? amount : room;
            }
        }
    }

    /// @param mode 0-4 within allowance and balance, 5 above the allowance, 6 above the balance,
    /// 7 to the zero address, 8 from the zero address, 9 any amount.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 rawAmount, uint8 mode)
        external
    {
        mode = mode % 10;
        address spender = _pick(spenderSeed);
        address owner = mode == 8 ? address(0) : _pick(ownerSeed);
        address to = mode == 7 ? address(0) : _pick(toSeed);
        uint256 approved = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        uint256 amount;
        if (mode < 5) {
            amount = rawAmount % ((balance < approved ? balance : approved) + 1);
        } else if (mode == 5 && approved != type(uint256).max) {
            amount = approved + 1 + rawAmount % (type(uint256).max - approved);
            ++overspendAttempts;
        } else if (mode == 6) {
            amount = balance + 1 + rawAmount % (type(uint256).max - balance);
            ++overspendAttempts;
        } else {
            amount = rawAmount;
        }
        if (owner == address(0) || to == address(0)) ++zeroAddressAttempts;

        bytes memory expectedError;
        if (approved != type(uint256).max && amount > approved) {
            expectedError =
                abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, spender, approved, amount);
        } else if (owner == address(0)) {
            expectedError = abi.encodeWithSelector(MADToken.ERC20InvalidSender.selector, address(0));
        } else if (to == address(0)) {
            expectedError = abi.encodeWithSelector(MADToken.ERC20InvalidReceiver.selector, address(0));
        } else if (amount > balance) {
            expectedError = abi.encodeWithSelector(MADToken.ERC20InsufficientBalance.selector, owner, balance, amount);
        }

        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(MADToken.transferFrom, (owner, to, amount)));
        _record(ok, ret, expectedError);
        if (!ok) return;

        totalSpentViaAllowance += amount;
        if (approved == type(uint256).max) {
            ++unlimitedSpends;
        } else {
            expectedAllowance[owner][spender] = approved - amount;
            totalFiniteSpentViaAllowance += amount;
        }
        if (owner != to) {
            expectedBalance[owner] -= amount;
            expectedBalance[to] += amount;
        }
    }
}

contract MADStatefulInvariantTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    MADToken internal token;
    MADStatefulHandler internal handler;

    function setUp() public {
        token = new MADToken();
        handler = new MADStatefulHandler(token, address(new InertHolder()));
        assertTrue(token.transfer(handler.holders(0), SUPPLY));
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_holdersAccountForTheWholeFixedSupply() public view {
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            address holder = handler.holders(i);
            uint256 actual = token.balanceOf(holder);
            assertEq(actual, handler.expectedBalance(holder));
            sum += actual;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesMatchModelAndZeroAddressHasNone() public view {
        for (uint256 i; i < 6; ++i) {
            address owner = handler.holders(i);
            for (uint256 j; j < 6; ++j) {
                address spender = handler.holders(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
            assertEq(token.allowance(owner, address(0)), 0);
            assertEq(token.allowance(address(0), owner), 0);
        }
    }

    /// @dev Nobody spends more through finite allowances than owners ever granted.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_finiteSpendingNeverExceedsGrants() public view {
        assertTrue(handler.totalFiniteSpentViaAllowance() <= handler.totalFiniteApproved());
        assertTrue(handler.totalFiniteSpentViaAllowance() <= handler.totalSpentViaAllowance());
    }

    /// @dev Guards against a vacuous run: both outcomes, and the edge inputs, must have been reached.
    function afterInvariant() public view {
        assertTrue(handler.successes() > 0);
        assertTrue(handler.expectedReverts() > 0);
        assertTrue(handler.zeroAddressAttempts() > 0);
        assertTrue(handler.overspendAttempts() > 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MADToken} from "../src/MADToken.sol";
import {TestBase} from "./utils/TestBase.sol";

/// @dev A closed set of actors lets the invariant account for every unit of token supply.
/// Expected balances and approvals are maintained independently of the token's storage.
contract MADTokenHandler is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    MADToken internal immutable token;
    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(MADToken token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("MAD invariant actor", i)))));
        }
        expectedBalance[actors[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = rawAmount % (expectedBalance[from] + 1);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        if (from != to) {
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 mode = rawAmount % 3;
        uint256 amount = mode == 0 ? 0 : mode == 1 ? type(uint256).max : rawAmount % (SUPPLY + 1);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    /// @dev Exercise both valid and invalid spends, including aliases between every actor role.
    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount, bool validAmount)
        external
    {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 approved = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        uint256 limit = balance < approved ? balance : approved;
        uint256 amount = validAmount ? rawAmount % (limit + 1) : rawAmount % (SUPPLY + 2);

        vm.prank(spender);
        (bool success, bytes memory data) =
            address(token).call(abi.encodeCall(MADToken.transferFrom, (owner, to, amount)));

        if (amount > approved || amount > balance) {
            assertFalse(success);
            // The invariant also checks that failed calls preserved every balance and allowance.
            return;
        }
        assertTrue(success);
        assertTrue(abi.decode(data, (bool)));
        if (approved != type(uint256).max) expectedAllowance[owner][spender] = approved - amount;
        if (owner != to) {
            expectedBalance[owner] -= amount;
            expectedBalance[to] += amount;
        }
    }
}

contract MADTokenInvariantTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    MADToken internal token;
    MADTokenHandler internal handler;

    function setUp() public {
        token = new MADToken();
        handler = new MADTokenHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));
    }

    /// @dev Foundry's invariant runner discovers this getter; only the handler is fuzzed.
    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_supplyBalancesAndAllowancesMatchModel() public view {
        uint256 accounted;
        for (uint256 i; i < 5; ++i) {
            address owner = handler.actors(i);
            uint256 actual = token.balanceOf(owner);
            assertEq(actual, handler.expectedBalance(owner));
            accounted += actual;
            for (uint256 j; j < 5; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
        assertEq(accounted, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}

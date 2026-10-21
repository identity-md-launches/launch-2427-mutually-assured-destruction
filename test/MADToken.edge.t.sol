// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MADToken} from "../src/MADToken.sol";
import {TestBase} from "./utils/TestBase.sol";

/// @dev Log-recording cheatcodes, which the shared TestBase does not declare.
interface VmLogs {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

/// @dev Deploys the token and moves part of the supply in the same transaction, as a launch factory does.
contract OneTransactionLauncher {
    function launch(address recipient, uint256 amount) external returns (MADToken token) {
        token = new MADToken();
        require(token.transfer(recipient, amount), "transfer failed");
    }
}

contract MADTokenEdgeTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    VmLogs internal constant logs = VmLogs(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    MADToken internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        token = new MADToken();
        alice = testAddress("edge alice");
        bob = testAddress("edge bob");
        spender = testAddress("edge spender");
    }

    // ---------------------------------------------------------------- supply and deployment

    function test_supplyIsExactlyTenToTheTwentySeventh() public view {
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
    }

    function test_deployAndDistributeInOneTransaction() public {
        OneTransactionLauncher launcher = new OneTransactionLauncher();
        MADToken launched = launcher.launch(alice, SUPPLY / 10);
        assertEq(launched.balanceOf(alice), SUPPLY / 10);
        assertEq(launched.balanceOf(address(launcher)), SUPPLY - SUPPLY / 10);
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_eachDeploymentMintsIndependently() public {
        MADToken second = new MADToken();
        assertTrue(token.transfer(alice, 1));
        assertEq(second.balanceOf(address(this)), SUPPLY);
        assertEq(second.balanceOf(alice), 0);
        assertEq(token.totalSupply() + second.totalSupply(), 2 * SUPPLY);
    }

    // ---------------------------------------------------------------- ABI return values

    function test_transferReturnsExactlyOneTrueWord() public {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(MADToken.transfer, (alice, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(uint256(bytes32(ret)), 1);
    }

    function test_approveAndTransferFromReturnExactlyOneTrueWord() public {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(MADToken.approve, (spender, 5)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(uint256(bytes32(ret)), 1);

        vm.prank(spender);
        (ok, ret) = address(token).call(abi.encodeCall(MADToken.transferFrom, (address(this), alice, 5)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(uint256(bytes32(ret)), 1);
    }

    // ---------------------------------------------------------------- events

    function test_transferFromEmitsOnlyTransferNoApproval() public {
        assertTrue(token.approve(spender, 10));
        logs.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 4));
        VmLogs.Log[] memory entries = logs.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].emitter, address(token));
        assertTrue(entries[0].topics[0] == TRANSFER_TOPIC);
        assertEq(uint256(entries[0].topics[1]), uint256(uint160(address(this))));
        assertEq(uint256(entries[0].topics[2]), uint256(uint160(alice)));
        assertEq(abi.decode(entries[0].data, (uint256)), 4);
    }

    function test_approveEmitsOnlyApproval() public {
        logs.recordLogs();
        assertTrue(token.approve(spender, 7));
        VmLogs.Log[] memory entries = logs.getRecordedLogs();
        assertEq(entries.length, 1);
        assertTrue(entries[0].topics[0] == APPROVAL_TOPIC);
        assertEq(uint256(entries[0].topics[1]), uint256(uint160(address(this))));
        assertEq(uint256(entries[0].topics[2]), uint256(uint160(spender)));
        assertEq(abi.decode(entries[0].data, (uint256)), 7);
    }

    function test_failedCallsEmitNothing() public {
        logs.recordLogs();
        (bool ok,) = address(token).call(abi.encodeCall(MADToken.transfer, (alice, SUPPLY + 1)));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeCall(MADToken.approve, (address(0), 1)));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeCall(MADToken.transferFrom, (address(this), alice, 1)));
        assertFalse(ok);
        assertEq(logs.getRecordedLogs().length, 0);
    }

    // ---------------------------------------------------------------- error precedence

    /// @dev The allowance is checked before the source: the zero address can never grant one.
    function test_transferFromZeroSourceWithValueFailsOnAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 1);
    }

    function test_transferFromZeroRecipientZeroValueFailsOnReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 0);
    }

    function test_transferFromAllowanceErrorPrecedesBalanceError() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 1));
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, spender, 1, 2));
        vm.prank(spender);
        token.transferFrom(alice, bob, 2);
    }

    function test_unlimitedAllowanceStillBoundByBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientBalance.selector, alice, 0, type(uint256).max));
        vm.prank(spender);
        token.transferFrom(alice, bob, type(uint256).max);
        assertEq(token.allowance(alice, spender), type(uint256).max);
    }

    function test_zeroSenderTransferRejectedBeforeBalance() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(address(0), type(uint256).max);
    }

    // ---------------------------------------------------------------- boundary amounts

    function test_transferMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(MADToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_transferOneUnitOverBalanceReverts() public {
        assertTrue(token.transfer(alice, 1 ether));
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientBalance.selector, alice, 1 ether, 1 ether + 1));
        vm.prank(alice);
        token.transfer(bob, 1 ether + 1);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    function test_allowanceOneBelowMaxIsFiniteAndDecreases() public {
        assertTrue(token.approve(spender, type(uint256).max - 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
    }

    function test_allowanceAboveSupplyIsStoredVerbatim() public {
        assertTrue(token.approve(spender, SUPPLY * 5));
        assertEq(token.allowance(address(this), spender), SUPPLY * 5);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.allowance(address(this), spender), SUPPLY * 4);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_selfApprovalByContractHolderSpendsLikeAnyOther() public {
        assertTrue(token.approve(address(this), type(uint256).max));
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.allowance(address(this), address(this)), type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_tokensSentToTokenContractAreStuck() public {
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        // Nothing on the token moves its own balance; only a holder's own call can.
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(token), address(this), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_allowanceOfReceiverUnaffectedByIncomingTransfer() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 3));
        assertTrue(token.transfer(alice, 100));
        assertEq(token.allowance(alice, spender), 3);
        assertEq(token.allowance(address(this), spender), 0);
    }

    // ---------------------------------------------------------------- fuzzed properties

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveStoresAnyValue(address owner, address spender_, uint256 amount) public {
        owner = address(uint160(bound(uint160(owner), 1, type(uint160).max)));
        spender_ = address(uint160(bound(uint160(spender_), 1, type(uint160).max)));
        vm.prank(owner);
        assertTrue(token.approve(spender_, amount));
        assertEq(token.allowance(owner, spender_), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unlimitedAllowanceNeverDecreases(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, a));
        assertTrue(token.transferFrom(address(this), bob, b));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY - a - b);
    }

    /// @dev Two-hop round trip: whatever leaves comes back, with nothing skimmed.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundTripIsLossless(address via, uint256 amount) public {
        via = address(uint160(bound(uint160(via), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(via, amount));
        vm.prank(via);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(via), via == address(this) ? SUPPLY : 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromAboveBalanceRevertsAndKeepsAllowance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);
        assertTrue(token.transfer(alice, held));
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max - 1));
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), type(uint256).max - 1);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max == type(uint256).max && min == 0) return x;
        return min + x % (max - min + 1);
    }
}

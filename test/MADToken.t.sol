// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MADToken} from "../src/MADToken.sol";
import {TestBase} from "./utils/TestBase.sol";

/// @dev Exercises deployment through another contract, including CREATE2, without a network.
contract TokenFactoryFixture {
    function deploy(bytes32 salt) external returns (MADToken) {
        return new MADToken{salt: salt}();
    }
}

/// @dev A contract that rejects calls can still receive ERC-20 balances without a callback.
contract RejectingRecipient {
    fallback() external {
        revert("unexpected callback");
    }
}

contract MADTokenTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    MADToken internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new MADToken();
        alice = testAddress("alice");
        bob = testAddress("bob");
        spender = testAddress("spender");
    }

    function test_metadataAndInitialSupply() public view {
        assertEq(token.name(), "Mutually Assured Destruction");
        assertEq(token.symbol(), "MAD");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_constructorEmitsSingleSupplyMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        MADToken fresh = new MADToken();
        assertEq(fresh.balanceOf(address(this)), SUPPLY);
    }

    function test_factoryDeploymentMintsOnlyToImmediateDeployer() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        MADToken deployed = factory.deploy(keccak256("MAD deployment test"));
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(deployed.balanceOf(address(deployed)), 0);
        assertTrue(address(deployed).code.length > 0);
        assertTrue(address(deployed).code.length <= 24_576);
    }

    function test_transferReturnsTrueAndEmitsExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 123 ether);
        assertTrue(token.transfer(alice, 123 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY - 123 ether);
        assertEq(token.balanceOf(alice), 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_entireSupplyCanRoundTrip() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_zeroTransferFromEmptyBalanceEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_selfTransferPreservesBalance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), address(this), SUPPLY);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_selfTransferStillRequiresBalance() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(alice, 1);
    }

    function test_transferRejectsZeroRecipientEvenForZeroValue() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRejectsZeroSender() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);
    }

    function test_transferToContractDoesNotCallRecipient() public {
        RejectingRecipient recipient = new RejectingRecipient();
        assertTrue(token.transfer(address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 1 ether);
    }

    function test_approvalEmitsAndCanBeOverwrittenAndRevoked() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 50 ether);
        assertTrue(token.approve(spender, 50 ether));
        assertEq(token.allowance(address(this), spender), 50 ether);
        assertTrue(token.approve(spender, 20 ether));
        assertEq(token.allowance(address(this), spender), 20 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 0);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(address(this), spender), 0);

        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_approvalDoesNotRequireBalanceOrMoveTokens() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalRejectsZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
    }

    function test_approvalRejectsZeroApprover() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(spender, 0);
    }

    function test_approvalsAreIsolatedByOwnerAndSpender() public {
        assertTrue(token.approve(spender, 20 ether));
        vm.prank(alice);
        assertTrue(token.approve(spender, 5 ether));
        assertTrue(token.approve(bob, 3 ether));
        assertEq(token.allowance(address(this), spender), 20 ether);
        assertEq(token.allowance(alice, spender), 5 ether);
        assertEq(token.allowance(address(this), bob), 3 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_transferFromConsumesFiniteAllowanceAndEmitsTransfer() public {
        assertTrue(token.approve(spender, 100 ether));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 60 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 60 ether));
        assertEq(token.allowance(address(this), spender), 40 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 60 ether);
        assertEq(token.balanceOf(alice), 60 ether);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 40 ether));
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    function test_transferFromPreservesUnlimitedAllowanceAcrossTransfers() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1 ether));
        assertTrue(token.transferFrom(address(this), bob, 2 ether));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 3 ether);
    }

    function test_transferFromRejectsUnapprovedSpender() public {
        assertTrue(token.approve(spender, 100 ether));
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        vm.prank(bob);
        token.transferFrom(address(this), alice, 1 ether);
        assertEq(token.allowance(address(this), spender), 100 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferFromRequiresAllowanceEvenWhenCallerIsOwner() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertTrue(token.approve(address(this), 1));
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), address(this)), 0);
    }

    function test_transferFromToSelfConsumesAllowanceWithoutChangingBalance() public {
        assertTrue(token.approve(spender, SUPPLY));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_transferFromZeroValueNeedsNoAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_transferFromRejectsZeroSource() public {
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 0);
    }

    function test_transferFromZeroRecipientRollsBackAllowance() public {
        assertTrue(token.approve(spender, 10 ether));
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 10 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferFromInsufficientBalanceRollsBackAllowance() public {
        assertTrue(token.transfer(alice, 5 ether));
        vm.prank(alice);
        assertTrue(token.approve(spender, 10 ether));
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientBalance.selector, alice, 5 ether, 6 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 6 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_launchAndTradingTokenLegsTransferExactAmounts() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        MADToken launched = factory.deploy(keccak256("distribution test"));
        address distributor = testAddress("distributor");
        address pool = testAddress("pool manager");
        address remainder = testAddress("remainder recipient");
        uint256 swarmShare = SUPPLY / 10;
        uint256 poolShare = SUPPLY * 6 / 10;
        uint256 remainderShare = SUPPLY - swarmShare - poolShare;

        vm.startPrank(address(factory));
        assertTrue(launched.transfer(distributor, swarmShare));
        assertTrue(launched.transfer(pool, poolShare));
        assertTrue(launched.transfer(remainder, remainderShare));
        vm.stopPrank();
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarmShare);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.balanceOf(remainder), remainderShare);

        vm.prank(distributor);
        assertTrue(launched.transfer(alice, swarmShare));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(alice), swarmShare);
        vm.prank(pool);
        assertTrue(launched.transfer(bob, 17 ether));
        assertEq(launched.balanceOf(bob), 17 ether);
        vm.prank(bob);
        assertTrue(launched.transfer(pool, 17 ether));
        assertEq(launched.balanceOf(bob), 0);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_noMintBurnFreezeSeizeOrUpgradeEntryPoints() public {
        assertTrue(token.transfer(alice, 10 ether));
        bytes[] memory calls = new bytes[](20);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1 ether);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("issue(uint256)", 1 ether);
        calls[4] = abi.encodeWithSignature("setMinter(address)", bob);
        calls[5] = abi.encodeWithSignature("initialize(address)", bob);
        calls[6] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[7] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        calls[8] = abi.encodeWithSignature("pause()");
        calls[9] = abi.encodeWithSignature("unpause()");
        calls[10] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[11] = abi.encodeWithSignature("freeze(address)", alice);
        calls[12] = abi.encodeWithSignature("seize(address)", alice);
        calls[13] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[14] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[15] = abi.encodeWithSignature("upgradeTo(address)", bob);
        calls[16] = abi.encodeWithSignature("setOwner(address)", bob);
        calls[17] = abi.encodeWithSignature("setBlacklist(address,bool)", alice, true);
        calls[18] = abi.encodeWithSignature("lock(address)", alice);
        calls[19] = abi.encodeWithSignature("disableTransfers()");
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSuccess,) = address(token).call(calls[i]);
            assertFalse(deployerSuccess);
            vm.prank(bob);
            (bool strangerSuccess,) = address(token).call(calls[i]);
            assertFalse(strangerSuccess);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(alice), 10 ether);
        }
        vm.expectRevert(abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, address(this), 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_rejectsNativeCurrencyAndUnknownCalls() public {
        vm.deal(address(this), 1 ether);
        (bool funded,) = address(token).call{value: 1 ether}("");
        assertFalse(funded);
        (bool unknown,) = address(token).call(hex"ffffffff");
        assertFalse(unknown);
        assertEq(address(token).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address recipient, uint256 rawAmount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        uint256 amount = rawAmount % (SUPPLY + 1);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_selfTransferConservesBalance(uint256 rawAmount) public {
        assertTrue(token.transfer(address(this), rawAmount % (SUPPLY + 1)));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_excessiveTransferRevertsWithoutChanges(uint256 rawAmount) public {
        uint256 amount = SUPPLY + 1 + rawAmount % (type(uint256).max - SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(MADToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_spendingFiniteApproval(uint256 rawApproved, uint256 rawSpent) public {
        uint256 approved = rawApproved % (SUPPLY + 1);
        uint256 spent = rawSpent % (approved + 1);
        assertTrue(token.approve(spender, approved));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, spent));
        assertEq(token.allowance(address(this), spender), approved - spent);
        assertEq(token.balanceOf(address(this)), SUPPLY - spent);
        assertEq(token.balanceOf(alice), spent);
    }

    function testFuzz_excessiveAllowanceSpendReverts(uint256 rawApproved) public {
        uint256 approved = rawApproved % SUPPLY;
        assertTrue(token.approve(spender, approved));
        vm.expectRevert(
            abi.encodeWithSelector(MADToken.ERC20InsufficientAllowance.selector, spender, approved, approved + 1)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, approved + 1);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Only the Foundry cheatcodes used by this project's tests. No external test dependencies.
interface Vm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data) external;
    function assume(bool condition) external;
    function deal(address account, uint256 balance) external;
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "uint mismatch");
    }

    function assertEq(address actual, address expected) internal pure {
        require(actual == expected, "address mismatch");
    }

    function assertEq(string memory actual, string memory expected) internal pure {
        require(keccak256(bytes(actual)) == keccak256(bytes(expected)), "string mismatch");
    }

    function assertTrue(bool condition) internal pure {
        require(condition, "expected true");
    }

    function assertFalse(bool condition) internal pure {
        require(!condition, "expected false");
    }

    function testAddress(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(label)))));
    }
}

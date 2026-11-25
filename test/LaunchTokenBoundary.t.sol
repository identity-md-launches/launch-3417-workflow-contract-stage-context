// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenBoundaryTest is Test {
    LaunchToken internal token;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal recipient;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function setUp() public {
        alice = makeAddr("token owner");
        bob = makeAddr("first spender");
        carol = makeAddr("other spender");
        recipient = makeAddr("token recipient");
        token = new LaunchToken();
        token.transfer(alice, SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzApprovalOverwritesAndRevocationDoesNotAffectOtherSpender(
        uint256 originalSeed,
        uint256 replacementSeed,
        uint256 spendSeed
    ) public {
        uint256 original = bound(originalSeed, 0, SUPPLY);
        uint256 replacement = bound(replacementSeed, 0, SUPPLY - 1);
        uint256 spend = bound(spendSeed, 0, replacement);
        vm.startPrank(alice);
        token.approve(bob, original);
        token.approve(carol, 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, bob, replacement);
        token.approve(bob, replacement);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), replacement, "replace instead of accumulate");

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, recipient, spend));
        assertEq(token.allowance(alice, bob), replacement - spend);
        assertEq(token.balanceOf(recipient), spend);
        assertEq(token.balanceOf(alice), SUPPLY - spend);

        vm.prank(alice);
        token.approve(bob, 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, recipient, 1);
        assertEq(token.allowance(alice, carol), 1, "other spender's authority is independent");
        vm.prank(carol);
        assertTrue(token.transferFrom(alice, recipient, 1));
        assertEq(token.balanceOf(recipient), spend + 1);
        assertEq(token.balanceOf(alice), SUPPLY - spend - 1);
        assertEq(token.allowance(alice, carol), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzDelegatedSelfTransferPreservesBalanceButConsumesFiniteAllowance(uint256 seed) public {
        uint256 amount = bound(seed, 0, SUPPLY);
        vm.prank(alice);
        token.approve(bob, amount + 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, alice, amount);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, alice, amount));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testUnlimitedAllowanceSurvivesRepeatedSpendAndFailedSpend() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, recipient, SUPPLY - 1);
        vm.prank(bob);
        token.transferFrom(alice, recipient, 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, recipient, 1);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(recipient), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(alice);
        token.approve(bob, 0);
        assertEq(token.allowance(alice, bob), 0);
    }

    function testMaximumUintTransferAndDelegatedTransferRevertAtomically() public {
        bytes memory reason =
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, alice, SUPPLY, type(uint256).max);
        vm.expectRevert(reason);
        vm.prank(alice);
        token.transfer(recipient, type(uint256).max);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.expectRevert(reason);
        vm.prank(bob);
        token.transferFrom(alice, recipient, type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testZeroTransferFromAnEmptyWalletIsValidAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(bob, recipient, 0);
        vm.prank(bob);
        assertTrue(token.transfer(recipient, 0));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function testZeroAmountDoesNotBypassInvalidAddressChecks() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(bob);
        token.transferFrom(alice, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(alice, bob), 0);
    }

    function testAnApprovalDoesNotAuthorizeAnotherOwnerOrAnotherSpender() public {
        vm.prank(alice);
        token.approve(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, carol, 0, 1));
        vm.prank(carol);
        token.transferFrom(alice, recipient, 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(carol, recipient, 1);
        assertEq(token.allowance(alice, bob), 1);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }
}

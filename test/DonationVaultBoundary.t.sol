// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DonationVault} from "../src/DonationVault.sol";

/// @dev A contract wallet fixture, used to check msg.sender attribution across
/// call boundaries. No ETH receiver callback is involved in an ERC-20 payout.
contract GiftWallet {
    function donate(LaunchToken token, DonationVault vault, uint256 amount) external returns (uint256) {
        token.approve(address(vault), amount);
        return vault.donate(amount);
    }

    function claim(DonationVault vault, uint256 id) external returns (uint256) {
        return vault.claim(id);
    }
}

contract DonationVaultBoundaryTest is Test {
    LaunchToken internal token;
    DonationVault internal vault;
    address internal alice;
    address internal bob;
    address internal carol;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    function setUp() public {
        alice = makeAddr("boundary donor");
        bob = makeAddr("boundary recipient");
        carol = makeAddr("boundary alternate recipient");
        token = new LaunchToken();
        vault = new DonationVault(address(token));
        token.transfer(alice, SUPPLY);
    }

    function testOneWeiGiftPaysExactlyAndTheEmptyVaultCanReopen() public {
        _donate(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.SelfClaim.selector, 1));
        vm.prank(alice);
        vault.claim(1);
        vm.prank(bob);
        assertEq(vault.claim(1), 1);
        assertEq(token.balanceOf(bob), 1);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(vault.points(alice), 1);

        assertEq(_donate(bob, 1), 2, "gift IDs never reset when outstanding becomes zero");
        vm.prank(carol);
        assertEq(vault.claim(2), 1);
        assertEq(token.balanceOf(carol), 1);
        assertEq(vault.points(alice), 1);
        assertEq(vault.points(bob), 1);
        assertEq(vault.points(carol), 0);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testEntireSupplyCanBeGiftedPaidAndGiftedAgain() public {
        _donate(alice, SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(vault)), SUPPLY);
        assertEq(vault.totalOutstanding(), SUPPLY);
        vm.prank(bob);
        assertEq(vault.claim(1), SUPPLY);
        assertEq(token.balanceOf(bob), SUPPLY);
        _donate(bob, SUPPLY);
        vm.prank(carol);
        assertEq(vault.claim(2), SUPPLY);
        assertEq(token.balanceOf(carol), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(vault.points(alice), SUPPLY);
        assertEq(vault.points(bob), SUPPLY);
        assertEq(vault.points(carol), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testMaximumUintDonationCannotCreatePointsOrConsumeUnlimitedAllowance() public {
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(DonationVault.TransferFailed.selector);
        vm.prank(alice);
        vault.donate(type(uint256).max);
        assertEq(vault.giftCount(), 0);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(vault.points(alice), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.allowance(alice, address(vault)), type(uint256).max);
        vm.prank(alice);
        assertEq(vault.donate(SUPPLY), 1, "failed call releases the lock");
        assertEq(vault.points(alice), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSplittingAGiftCannotRoundAwayPointsOrChangeTotalPayout(
        uint256 totalSeed,
        uint256 splitSeed,
        bool reverse
    ) public {
        uint256 total = bound(totalSeed, 2, SUPPLY);
        uint256 first = bound(splitSeed, 1, total - 1);
        uint256 snapshot = vm.snapshotState();
        _donate(alice, total);
        vm.prank(bob);
        uint256 wholePayout = vault.claim(1);
        uint256 wholePoints = vault.points(alice);
        uint256 donorBalance = token.balanceOf(alice);
        uint256 recipientBalance = token.balanceOf(bob);
        assertTrue(vm.revertToStateAndDelete(snapshot));

        _donate(alice, first);
        _donate(alice, total - first);
        vm.prank(bob);
        uint256 firstPayout = vault.claim(reverse ? 2 : 1);
        vm.prank(bob);
        uint256 secondPayout = vault.claim(reverse ? 1 : 2);
        assertEq(firstPayout + secondPayout, wholePayout);
        assertEq(wholePayout, total);
        assertEq(vault.points(alice), wholePoints);
        assertEq(wholePoints, total);
        assertEq(token.balanceOf(alice), donorBalance);
        assertEq(token.balanceOf(bob), recipientBalance);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertTrue(vault.isClaimed(1) && vault.isClaimed(2));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzUnknownGiftRejectionCannotBlockExistingGift(uint256 idSeed) public {
        _donate(alice, 1.5e18);
        uint256 id = idSeed == 0 ? 0 : bound(idSeed, 2, type(uint256).max);
        (address donor, uint256 amount, bool claimed) = vault.getGift(id);
        assertEq(donor, address(0));
        assertEq(amount, 0);
        assertFalse(claimed);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.UnknownGift.selector, id));
        vm.prank(bob);
        vault.claim(id);
        assertEq(vault.giftCount(), 1);
        assertEq(vault.points(alice), 1.5e18);
        assertEq(vault.totalOutstanding(), 1.5e18);
        assertFalse(vault.isClaimed(1));
        vm.prank(bob);
        assertEq(vault.claim(1), 1.5e18);
        assertEq(token.balanceOf(bob), 1.5e18);
        assertEq(vault.totalOutstanding(), 0);
    }

    function testContractWalletsAreAttributedByCallerAndReceiveTheirOwnPayout() public {
        GiftWallet donorWallet = new GiftWallet();
        GiftWallet claimWallet = new GiftWallet();
        uint256 amount = 7.25e18;
        vm.prank(alice);
        token.transfer(address(donorWallet), amount);
        vm.prank(alice);
        assertEq(donorWallet.donate(token, vault, amount), 1);
        assertEq(vault.giftDonor(1), address(donorWallet));
        assertEq(vault.points(address(donorWallet)), amount);
        assertEq(vault.points(alice), 0);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.SelfClaim.selector, 1));
        donorWallet.claim(vault, 1);
        vm.prank(bob);
        assertEq(claimWallet.claim(vault, 1), amount);
        assertEq(token.balanceOf(address(claimWallet)), amount);
        assertEq(token.balanceOf(bob), 0, "payout belongs to calling wallet contract");
        assertEq(vault.points(address(donorWallet)), amount);
        assertEq(vault.points(address(claimWallet)), 0);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.AlreadyClaimed.selector, 1));
        vm.prank(carol);
        claimWallet.claim(vault, 1);
    }

    function _donate(address donor, uint256 amount) private returns (uint256) {
        vm.prank(donor);
        token.approve(address(vault), amount);
        vm.prank(donor);
        return vault.donate(amount);
    }
}

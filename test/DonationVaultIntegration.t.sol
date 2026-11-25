// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchToken} from "../src/LaunchToken.sol";
import {DonationVault} from "../src/DonationVault.sol";

interface IntegrationVm {
    function prank(address sender) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
}

contract DonationVaultIntegrationTest {
    IntegrationVm private constant vm = IntegrationVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant STARTING_BALANCE = 100e18;
    uint256 private constant SUPPLY = 1_000_000_000e18;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA201);

    LaunchToken private token;
    DonationVault private vault;

    event Donated(uint256 indexed giftId, address indexed donor, uint256 amount);
    event Claimed(uint256 indexed giftId, address indexed claimer, uint256 amount);

    function setUp() public {
        token = new LaunchToken();
        vault = new DonationVault(address(token));
        require(token.transfer(ALICE, STARTING_BALANCE), "fund alice");
        require(token.transfer(BOB, STARTING_BALANCE), "fund bob");
        require(token.transfer(CAROL, STARTING_BALANCE), "fund carol");
    }

    function testApproveDonateAndClaimFractionalGift() public {
        uint256 amount = 1.5e18;
        vm.prank(ALICE);
        require(token.approve(address(vault), amount), "approve exact amount");
        require(token.allowance(ALICE, address(vault)) == amount, "approval stored");

        vm.expectEmit(true, true, false, true, address(vault));
        emit Donated(1, ALICE, amount);
        vm.prank(ALICE);
        uint256 id = vault.donate(amount);
        require(id == 1 && vault.giftCount() == 1, "first gift");
        require(token.allowance(ALICE, address(vault)) == 0, "approval consumed");
        require(token.balanceOf(ALICE) == STARTING_BALANCE - amount, "donor paid exact amount");
        require(vault.points(ALICE) == amount, "fractional points credited");
        (address donor, uint256 recordedAmount, bool claimed) = vault.getGift(id);
        require(donor == ALICE && recordedAmount == amount && !claimed, "gift recorded");
        _assertOutstanding(amount);

        vm.expectRevert(abi.encodeWithSelector(DonationVault.SelfClaim.selector, id));
        vm.prank(ALICE);
        vault.claim(id);
        require(!vault.isClaimed(id), "failed self-claim leaves gift open");
        _assertOutstanding(amount);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Claimed(id, BOB, amount);
        vm.prank(BOB);
        require(vault.claim(id) == amount, "full payout returned");
        require(token.balanceOf(BOB) == STARTING_BALANCE + amount, "second wallet received gift");
        require(vault.isClaimed(id), "gift claimed");
        require(vault.points(ALICE) == amount, "donor points persist");
        require(vault.points(BOB) == 0, "claiming earns no points");
        _assertOutstanding(0);

        vm.expectRevert(abi.encodeWithSelector(DonationVault.AlreadyClaimed.selector, id));
        vm.prank(CAROL);
        vault.claim(id);
        require(token.balanceOf(CAROL) == STARTING_BALANCE, "losing claimant receives nothing");
        require(vault.points(ALICE) == amount, "failed repeat claim preserves points");
        require(token.totalSupply() == SUPPLY, "supply unchanged");
        _assertOutstanding(0);
    }

    function testDonationAboveBalanceRevertsAtomically() public {
        uint256 amount = STARTING_BALANCE + 1;
        vm.prank(ALICE);
        require(token.approve(address(vault), amount), "approve");

        vm.expectRevert(abi.encodeWithSelector(DonationVault.TransferFailed.selector));
        vm.prank(ALICE);
        vault.donate(amount);

        _assertFailedDonation(amount);
        require(_approveAndDonate(ALICE, STARTING_BALANCE) == 1, "valid donation still succeeds");
        _assertOutstanding(STARTING_BALANCE);
    }

    function testDonationAboveAllowanceRevertsAtomically() public {
        uint256 approved = 1e18;
        vm.prank(ALICE);
        require(token.approve(address(vault), approved), "approve");

        vm.expectRevert(abi.encodeWithSelector(DonationVault.TransferFailed.selector));
        vm.prank(ALICE);
        vault.donate(approved + 1);

        _assertFailedDonation(approved);
        require(_approveAndDonate(ALICE, approved) == 1, "valid donation still succeeds");
        _assertOutstanding(approved);
    }

    /// @dev Reproduces audit abb45648: BOB represents a second wallet controlled by ALICE.
    function testPointsCanBeFarmedThroughASecondWallet() public {
        vm.prank(ALICE);
        require(token.approve(address(vault), type(uint256).max), "approve repeated donations");

        for (uint256 i; i < 10; ++i) {
            vm.prank(ALICE);
            uint256 id = vault.donate(STARTING_BALANCE);
            vm.prank(BOB);
            require(vault.claim(id) == STARTING_BALANCE, "second wallet claims");
            vm.prank(BOB);
            require(token.transfer(ALICE, STARTING_BALANCE), "return tokens to donor");

            require(token.balanceOf(ALICE) == STARTING_BALANCE, "donor recovers all tokens");
            require(token.balanceOf(BOB) == STARTING_BALANCE, "second wallet retains no tokens");
            require(vault.points(ALICE) == (i + 1) * STARTING_BALANCE, "points count gross donations");
            require(vault.isClaimed(id), "gift paid");
            _assertOutstanding(0);
        }

        require(vault.giftCount() == 10, "ten gifts");
        require(vault.points(ALICE) == 1000e18, "1000 points without a net donation");
        require(vault.points(BOB) == 0, "claiming and transferring earn no points");
        require(token.totalSupply() == SUPPLY, "no token inflation");
    }

    /// @dev Reproduces audit 17c3d40b: later gifts cannot pay out a direct-transfer surplus.
    function testDirectTransferStaysLockedAfterLaterGiftIsClaimed() public {
        uint256 surplus = 5e18;
        vm.prank(BOB);
        require(token.transfer(address(vault), surplus), "plain transfer");

        require(vault.giftCount() == 0, "direct transfer creates no gift");
        require(vault.totalOutstanding() == 0, "direct transfer is not outstanding");
        require(vault.points(BOB) == 0, "direct transfer earns no points");
        require(token.balanceOf(address(vault)) == surplus, "surplus held in vault");
        vm.expectRevert(abi.encodeWithSelector(DonationVault.UnknownGift.selector, 0));
        vm.prank(BOB);
        vault.claim(0);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.UnknownGift.selector, 1));
        vm.prank(CAROL);
        vault.claim(1);

        uint256 amount = 1.5e18;
        uint256 id = _approveAndDonate(ALICE, amount);
        require(vault.giftAmount(id) == amount, "gift excludes surplus");
        require(vault.totalOutstanding() == amount, "only donation is outstanding");
        require(token.balanceOf(address(vault)) == surplus + amount, "gift and surplus held");
        vm.prank(CAROL);
        require(vault.claim(id) == amount, "only recorded gift paid");

        require(vault.totalOutstanding() == 0, "all gifts paid");
        require(token.balanceOf(address(vault)) == surplus, "surplus still locked");
        require(token.balanceOf(BOB) == STARTING_BALANCE - surplus, "direct sender is not refunded");
        require(token.balanceOf(CAROL) == STARTING_BALANCE + amount, "claimer receives no surplus");
        require(vault.points(ALICE) == amount && vault.points(BOB) == 0, "only donation credits points");
        vm.expectRevert(abi.encodeWithSelector(DonationVault.AlreadyClaimed.selector, id));
        vm.prank(BOB);
        vault.claim(id);
        require(token.balanceOf(address(vault)) == surplus, "repeat claim cannot recover surplus");
    }

    function testFuzzMixedDonationsAndClaimsConserveBalances(uint256 aliceSeed, uint256 bobSeed, bool reverse) public {
        uint256 aliceAmount = aliceSeed % STARTING_BALANCE + 1;
        uint256 bobAmount = bobSeed % STARTING_BALANCE + 1;
        uint256 aliceId = _approveAndDonate(ALICE, aliceAmount);
        uint256 bobId = _approveAndDonate(BOB, bobAmount);
        require(aliceId == 1 && bobId == 2, "sequential gifts");
        require(token.allowance(ALICE, address(vault)) == 0, "alice approval consumed");
        require(token.allowance(BOB, address(vault)) == 0, "bob approval consumed");
        _assertOutstanding(aliceAmount + bobAmount);

        uint256 firstId = reverse ? bobId : aliceId;
        uint256 secondId = reverse ? aliceId : bobId;
        uint256 firstAmount = reverse ? bobAmount : aliceAmount;
        uint256 secondAmount = reverse ? aliceAmount : bobAmount;
        vm.prank(CAROL);
        require(vault.claim(firstId) == firstAmount, "first payout");
        require(vault.isClaimed(firstId) && !vault.isClaimed(secondId), "only first gift claimed");
        _assertOutstanding(secondAmount);
        vm.prank(CAROL);
        require(vault.claim(secondId) == secondAmount, "second payout");
        require(vault.isClaimed(secondId), "second gift claimed");
        _assertOutstanding(0);

        require(vault.points(ALICE) == aliceAmount, "alice points persist");
        require(vault.points(BOB) == bobAmount, "bob points persist");
        require(vault.points(CAROL) == 0, "claimer has no donor points");
        require(token.balanceOf(ALICE) == STARTING_BALANCE - aliceAmount, "alice balance");
        require(token.balanceOf(BOB) == STARTING_BALANCE - bobAmount, "bob balance");
        require(token.balanceOf(CAROL) == STARTING_BALANCE + aliceAmount + bobAmount, "carol balance");
        require(token.balanceOf(address(this)) == SUPPLY - 3 * STARTING_BALANCE, "unspent supply");
        require(token.totalSupply() == SUPPLY, "supply conserved");
    }

    function _approveAndDonate(address donor, uint256 amount) private returns (uint256) {
        vm.prank(donor);
        require(token.approve(address(vault), amount), "approve");
        vm.prank(donor);
        return vault.donate(amount);
    }

    function _assertOutstanding(uint256 expected) private view {
        require(vault.totalOutstanding() == expected, "outstanding total");
        require(token.balanceOf(address(vault)) == expected, "vault balance matches gifts");
    }

    function _assertFailedDonation(uint256 expectedAllowance) private view {
        require(token.allowance(ALICE, address(vault)) == expectedAllowance, "allowance rolled back");
        require(token.balanceOf(ALICE) == STARTING_BALANCE, "donor balance unchanged");
        require(vault.giftCount() == 0, "no gift created");
        require(vault.points(ALICE) == 0, "no points credited");
        _assertOutstanding(0);
    }
}

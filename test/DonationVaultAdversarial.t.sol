// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {DonationVault} from "../src/DonationVault.sol";
import {AdversarialDonationToken as Token} from "./helpers/AdversarialDonationToken.sol";

/// @dev These token variants exercise the vault's defensive call wrapper.
/// The production pairing is tested separately with the actual LaunchToken.
contract DonationVaultAdversarialTest is Test {
    Token internal token;
    DonationVault internal vault;
    address internal alice;
    address internal bob;
    address internal carol;
    uint256 internal constant FUNDS = 100e18;
    uint256 internal constant GIFT = 1.5e18;

    event Donated(uint256 indexed giftId, address indexed donor, uint256 amount);
    event Claimed(uint256 indexed giftId, address indexed claimer, uint256 amount);

    function setUp() public {
        alice = makeAddr("adversarial donor");
        bob = makeAddr("first claimant");
        carol = makeAddr("second claimant");
        token = new Token();
        vault = new DonationVault(address(token));
        token.mint(alice, FUNDS);
        token.mint(address(token), FUNDS);
        vm.prank(alice);
        token.approve(address(vault), FUNDS);
    }

    function testDepositReturningFalseAfterMovingTokensRollsBackAndCanRetry() public {
        _failedDeposit(Token.Mode.FalseReturn, abi.encodeWithSelector(DonationVault.TransferFailed.selector));
    }

    function testDepositRevertingAfterMovingTokensRollsBackAndCanRetry() public {
        _failedDeposit(Token.Mode.RevertCall, abi.encodeWithSelector(DonationVault.TransferFailed.selector));
    }

    function testDepositReportingSuccessWithoutReceiptCannotCreateGift() public {
        _failedDeposit(Token.Mode.NoMovement, abi.encodeWithSelector(DonationVault.NothingReceived.selector));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzShortDepositResponseRollsBack(uint8 lengthSeed) public {
        token.setShortLength(bound(lengthSeed, 1, 31));
        _failedDeposit(Token.Mode.ShortReturn, abi.encodeWithSelector(DonationVault.TransferFailed.selector));
    }

    function testNonCanonicalBooleanDepositRollsBackAndCanRetry() public {
        _failedDeposit(Token.Mode.NonBoolean, bytes(""));
    }

    function testPayoutReturningFalseAfterMovingTokensRollsBackAndCanRetry() public {
        _failedPayout(Token.Mode.FalseReturn, abi.encodeWithSelector(DonationVault.TransferFailed.selector));
    }

    function testPayoutRevertingAfterMovingTokensRollsBackAndCanRetry() public {
        _failedPayout(Token.Mode.RevertCall, abi.encodeWithSelector(DonationVault.TransferFailed.selector));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzShortPayoutResponseRollsBack(uint8 lengthSeed) public {
        token.setShortLength(bound(lengthSeed, 1, 31));
        _failedPayout(Token.Mode.ShortReturn, abi.encodeWithSelector(DonationVault.TransferFailed.selector));
    }

    function testNonCanonicalBooleanPayoutRollsBackAndCanRetry() public {
        _failedPayout(Token.Mode.NonBoolean, bytes(""));
    }

    function testNoReturnTokenDonationAndPayoutMoveFullAmount() public {
        _optionalReturnRoundTrip(Token.Mode.NoReturn);
    }

    function testTrueWithExtraReturnDataDonationAndPayoutMoveFullAmount() public {
        _optionalReturnRoundTrip(Token.Mode.ExtendedTrue);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFeeOnDepositCreditsOnlyReceivedTokens(uint256 seed, uint16 feeSeed) public {
        uint256 amount = bound(seed, 1, FUNDS);
        uint256 feeBps = bound(feeSeed, 0, 9999);
        uint256 net = amount - amount * feeBps / 10_000;
        token.setDepositFee(feeBps);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Donated(1, alice, net);
        vm.prank(alice);
        assertEq(vault.donate(amount), 1);
        assertEq(vault.giftAmount(1), net);
        assertEq(vault.points(alice), net);
        assertEq(vault.totalOutstanding(), net);
        assertEq(token.balanceOf(address(vault)), net);
        assertEq(token.balanceOf(alice), FUNDS - amount);
        vm.prank(bob);
        assertEq(vault.claim(1), net);
        assertEq(token.balanceOf(bob), net);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(vault.points(alice), net);
    }

    function testFullyTaxedDonationRevertsAndRestoresBurnedBalanceAndAllowance() public {
        token.setDepositFee(10_000);
        vm.expectRevert(DonationVault.NothingReceived.selector);
        vm.prank(alice);
        vault.donate(GIFT);
        _assertEmpty();
        token.setDepositFee(0);
        _donate(GIFT);
        assertEq(vault.giftCount(), 1);
    }

    function testDepositCannotReenterDonate() public {
        token.armCallback(address(vault), abi.encodeCall(vault.donate, (1)), true, false);
        _donate(GIFT);
        _assertCallbackRejected();
        assertEq(vault.giftCount(), 1);
        assertEq(vault.points(address(token)), 0);
        assertEq(token.balanceOf(address(token)), FUNDS);
        assertEq(vault.totalOutstanding(), GIFT);
        _donate(1);
        assertEq(vault.giftCount(), 2, "lock released after successful outer deposit");
    }

    function testDepositCannotReenterClaimOfAnotherGift() public {
        _donate(GIFT);
        token.armCallback(address(vault), abi.encodeCall(vault.claim, (1)), true, false);
        _donate(1);
        _assertCallbackRejected();
        assertFalse(vault.isClaimed(1));
        assertEq(vault.totalOutstanding(), GIFT + 1);
        assertEq(token.balanceOf(address(token)), FUNDS);
        vm.prank(bob);
        assertEq(vault.claim(1), GIFT);
    }

    function testPayoutCannotReenterDonate() public {
        _donate(GIFT);
        token.armCallback(address(vault), abi.encodeCall(vault.donate, (1)), false, true);
        vm.prank(bob);
        assertEq(vault.claim(1), GIFT);
        _assertCallbackRejected();
        assertEq(vault.giftCount(), 1);
        assertEq(vault.points(address(token)), 0);
        assertEq(token.balanceOf(address(token)), FUNDS);
        assertEq(token.balanceOf(bob), GIFT);
        assertEq(vault.totalOutstanding(), 0);
    }

    function testPayoutCannotReenterClaimOfAnotherGift() public {
        _donate(GIFT);
        _donate(1);
        token.armCallback(address(vault), abi.encodeCall(vault.claim, (2)), false, true);
        vm.prank(bob);
        assertEq(vault.claim(1), GIFT);
        _assertCallbackRejected();
        assertFalse(vault.isClaimed(2), "callback must not steal another donor's gift");
        assertEq(vault.totalOutstanding(), 1);
        assertEq(token.balanceOf(address(token)), FUNDS);
        vm.prank(carol);
        assertEq(vault.claim(2), 1, "unrelated gift stays claimable");
        assertEq(token.balanceOf(carol), 1);
    }

    function testPayoutCannotReenterSameClaim() public {
        _donate(GIFT);
        token.armCallback(address(vault), abi.encodeCall(vault.claim, (1)), false, true);
        vm.prank(bob);
        vault.claim(1);
        _assertCallbackRejected();
        assertEq(token.balanceOf(bob), GIFT);
        assertEq(token.balanceOf(address(token)), FUNDS);
        assertEq(vault.totalOutstanding(), 0);
    }

    function testMissingTokenCodeCannotCreateAnUnbackedGiftAndLockRecovers() public {
        bytes memory runtime = address(token).code;
        vm.etch(address(token), bytes(""));
        vm.prank(alice);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.donate, (GIFT)));
        assertFalse(ok);
        vm.etch(address(token), runtime);
        _assertEmpty();
        _donate(GIFT);
        assertEq(vault.giftCount(), 1);
    }

    function testMissingTokenCodeCannotConsumeAnExistingGift() public {
        _donate(GIFT);
        bytes memory runtime = address(token).code;
        vm.etch(address(token), bytes(""));
        vm.expectRevert(DonationVault.TransferFailed.selector);
        vm.prank(bob);
        vault.claim(1);
        assertFalse(vault.isClaimed(1));
        assertEq(vault.totalOutstanding(), GIFT);
        vm.etch(address(token), runtime);
        vm.prank(carol);
        assertEq(vault.claim(1), GIFT);
        assertEq(token.balanceOf(carol), GIFT);
    }

    function _failedDeposit(Token.Mode mode, bytes memory expectedReason) internal {
        token.setModes(mode, Token.Mode.Normal);
        vm.prank(alice);
        (bool ok, bytes memory reason) = address(vault).call(abi.encodeCall(vault.donate, (GIFT)));
        assertFalse(ok, "malformed or failed token deposit must revert");
        if (mode != Token.Mode.NonBoolean) assertEq(reason, expectedReason);
        _assertEmpty();
        token.setModes(Token.Mode.Normal, Token.Mode.Normal);
        assertEq(_donate(GIFT), 1, "failed deposit consumes neither ID nor lock");
        assertEq(vault.points(alice), GIFT);
        assertEq(token.balanceOf(alice), FUNDS - GIFT);
        assertEq(token.balanceOf(address(vault)), GIFT);
    }

    function _failedPayout(Token.Mode mode, bytes memory expectedReason) internal {
        _donate(GIFT);
        _donate(1);
        token.setModes(Token.Mode.Normal, mode);
        vm.prank(bob);
        (bool ok, bytes memory reason) = address(vault).call(abi.encodeCall(vault.claim, (1)));
        assertFalse(ok, "malformed or failed token payout must revert");
        if (mode != Token.Mode.NonBoolean) assertEq(reason, expectedReason);
        assertFalse(vault.isClaimed(1));
        assertFalse(vault.isClaimed(2));
        assertEq(vault.giftCount(), 2);
        assertEq(vault.totalOutstanding(), GIFT + 1);
        assertEq(vault.points(alice), GIFT + 1);
        assertEq(token.balanceOf(address(vault)), GIFT + 1);
        assertEq(token.balanceOf(bob), 0, "token effects also roll back");
        token.setModes(Token.Mode.Normal, Token.Mode.Normal);
        vm.prank(carol);
        assertEq(vault.claim(2), 1, "unrelated gift still pays");
        vm.prank(bob);
        assertEq(vault.claim(1), GIFT, "failed claim can be retried");
        assertEq(token.balanceOf(bob), GIFT);
        assertEq(token.balanceOf(carol), 1);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(vault.points(alice), GIFT + 1);
    }

    function _optionalReturnRoundTrip(Token.Mode mode) internal {
        token.setModes(mode, mode);
        assertEq(_donate(GIFT), 1);
        assertEq(vault.points(alice), GIFT);
        assertEq(token.balanceOf(address(vault)), GIFT);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Claimed(1, bob, GIFT);
        vm.prank(bob);
        assertEq(vault.claim(1), GIFT);
        assertEq(token.balanceOf(bob), GIFT);
        assertEq(token.balanceOf(alice), FUNDS - GIFT);
        assertEq(vault.points(alice), GIFT);
        assertEq(vault.points(bob), 0);
        assertEq(vault.totalOutstanding(), 0);
    }

    function _assertEmpty() internal view {
        assertEq(vault.giftCount(), 0);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(vault.points(alice), 0);
        assertEq(token.balanceOf(alice), FUNDS);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.allowance(alice, address(vault)), FUNDS);
        (address donor, uint256 amount, bool claimed) = vault.getGift(1);
        assertEq(donor, address(0));
        assertEq(amount, 0);
        assertFalse(claimed);
    }

    function _assertCallbackRejected() internal view {
        assertEq(token.callbackAttempts(), 1, "callback must actually execute");
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(DonationVault.Reentrancy.selector));
    }

    function _donate(uint256 amount) internal returns (uint256) {
        vm.prank(alice);
        return vault.donate(amount);
    }
}

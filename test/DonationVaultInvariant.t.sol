// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DonationVault} from "../src/DonationVault.sol";
import {DonationSequenceHandler} from "./helpers/DonationSequenceHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract DonationVaultInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    LaunchToken internal token;
    DonationVault internal vault;
    DonationSequenceHandler internal handler;

    function setUp() public {
        token = new LaunchToken();
        vault = new DonationVault(address(token));
        handler = new DonationSequenceHandler(token, vault);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), SUPPLY / 4);
        }

        // Exercise both open and paid gifts before fuzzing; randomized actions
        // still start from actors funded solely by real fixed-supply transfers.
        handler.donate(0, 0, false);
        handler.donate(1, 2, true);
        handler.claimOpen(0, 2);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.claimOpen.selector;
        selectors[3] = handler.unknownClaim.selector;
        selectors[4] = handler.invalidDonation.selector;
        selectors[5] = handler.directTransfer.selector;
        selectors[6] = handler.transfer.selector;
        selectors[7] = handler.approve.selector;
        selectors[8] = handler.transferFrom.selector;
        selectors[9] = handler.roundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantFixedSupplyAndAllBalancesAreConserved() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertLe(handler.paid(), handler.donated(), "payouts cannot exceed gifts received");
        uint256 expectedVault = handler.donated() - handler.paid() + handler.surplus();
        assertEq(token.balanceOf(address(vault)), expectedVault, "vault balance versus independent cash flow");
        uint256 allBalances = token.balanceOf(address(vault));
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "actor cash flow");
            allBalances += token.balanceOf(actor);
        }
        assertEq(allBalances, SUPPLY, "no lost, minted or burned tokens");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariantGiftsRemainImmutableAndPayOnlyOnce() public view {
        uint256 count = handler.giftCount();
        assertEq(vault.giftCount(), count);
        uint256 outstanding;
        uint256 claimedAmount;
        uint256 claimedCount;
        for (uint256 i; i < count; ++i) {
            (address donor, uint256 amount, bool claimed) = handler.gifts(i);
            (address actualDonor, uint256 actualAmount, bool actualClaimed) = vault.getGift(i + 1);
            assertEq(actualDonor, donor);
            assertEq(actualAmount, amount);
            assertEq(actualClaimed, claimed, "claimed gifts must never reopen");
            assertEq(vault.giftDonor(i + 1), donor);
            assertEq(vault.giftAmount(i + 1), amount);
            assertEq(vault.isClaimed(i + 1), claimed);
            if (claimed) {
                claimedAmount += amount;
                ++claimedCount;
            } else {
                outstanding += amount;
            }
        }
        assertEq(vault.totalOutstanding(), outstanding, "sum of unclaimed gifts");
        assertEq(claimedAmount, handler.paid());
        assertEq(claimedCount, handler.successfulClaims(), "one payout per closed gift");
        assertEq(token.balanceOf(address(vault)), outstanding + handler.surplus());
    }

    function invariantPointsRemainWithTheirDonorsAfterPayout() public view {
        uint256 totalPoints;
        for (uint256 i; i < 4; ++i) {
            address donor = handler.actors(i);
            uint256 recordedDonations;
            for (uint256 j; j < handler.giftCount(); ++j) {
                (address giftDonor, uint256 amount,) = handler.gifts(j);
                if (giftDonor == donor) recordedDonations += amount;
            }
            assertEq(vault.points(donor), handler.donatedBy(donor));
            assertEq(vault.points(donor), recordedDonations, "points include both open and paid gifts");
            totalPoints += vault.points(donor);
        }
        assertEq(totalPoints, handler.donated());
        assertEq(vault.points(address(vault)), 0);
        assertEq(vault.points(address(handler)), 0);
    }

    function invariantCallOutcomesAndAllowancesMatchTheModel() public view {
        assertFalse(handler.unexpectedResult(), "unexpected success, failure, revert reason or return value");
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
            assertEq(token.allowance(owner, address(vault)), handler.expectedAllowance(owner, address(vault)));
        }
        (address donor, uint256 amount, bool claimed) = vault.getGift(handler.giftCount() + 1);
        assertEq(donor, address(0), "failed actions must not create phantom gifts");
        assertEq(amount, 0);
        assertFalse(claimed);
    }

    /// @dev Exit liveness is checked after EVERY random sequence, including ones
    /// containing self/repeat claims, revoked approvals, and failed donations.
    function afterInvariant() public {
        handler.drain();
        invariantFixedSupplyAndAllBalancesAreConserved();
        invariantGiftsRemainImmutableAndPayOnlyOnce();
        invariantPointsRemainWithTheirDonorsAfterPayout();
        invariantCallOutcomesAndAllowancesMatchTheModel();
        assertEq(vault.totalOutstanding(), 0, "every open gift can still pay");
        assertEq(token.balanceOf(address(vault)), handler.surplus());
        assertEq(handler.paid(), handler.donated());
    }

    function testHandlerExercisesSuccessAndFailureActions() public {
        handler.approve(2, 3, type(uint256).max);
        handler.transferFrom(2, 3, 0, 17, false);
        handler.transferFrom(2, 3, 0, 0, true);
        handler.approve(2, 3, 0);
        handler.transferFrom(2, 3, 0, 1, true);
        handler.invalidDonation(0, 0, 0);
        handler.invalidDonation(0, 1, 0);
        handler.invalidDonation(0, 2, 5);
        handler.unknownClaim(type(uint256).max, 1);
        handler.donate(0, 2, false);
        handler.claim(2, 0); // donor's own gift
        handler.claimOpen(2, 1);
        handler.claim(2, 2); // repeat claim
        handler.directTransfer(2, 0);
        handler.transfer(0, 0, 17); // self transfer
        handler.transfer(0, 3, 0); // zero transfer
        handler.roundTrip(3, 2);
        assertGt(handler.rejectedCalls(), 5);
        assertGt(handler.successfulClaims(), 1);
        afterInvariant();
    }
}

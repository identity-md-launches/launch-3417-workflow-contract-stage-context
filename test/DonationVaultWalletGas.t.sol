// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WalletGas} from "./helpers/WalletGas.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DonationVault} from "../src/DonationVault.sol";
import {AdversarialDonationToken as Token} from "./helpers/AdversarialDonationToken.sol";

/// @dev Both vault entry points use _safeCall's checked low-level token call.
/// Compare returns AND events at the minimum successful gas limit using the
/// supplied helper, including a final payout that clears storage for a refund.
contract DonationVaultWalletGasTest is WalletGas {
    LaunchToken internal token;
    DonationVault internal vault;
    address internal donor;
    address internal claimant;

    function setUp() public {
        donor = makeAddr("wallet gas donor");
        claimant = makeAddr("wallet gas claimant");
        token = new LaunchToken();
        vault = new DonationVault(address(token));
        token.transfer(donor, token.totalSupply());
    }

    function testFirstFractionalDonationAtWalletGas() public {
        _approve(1.5e18);
        assertSameAtWalletGas(donor, address(vault), abi.encodeCall(vault.donate, (1.5e18)));
        assertEq(vault.giftCount(), 0, "helper restores the pre-call state");
        assertEq(token.allowance(donor, address(vault)), 1.5e18);
    }

    function testOneWeiDonationWithUnlimitedApprovalAtWalletGas() public {
        _approve(type(uint256).max);
        assertSameAtWalletGas(donor, address(vault), abi.encodeCall(vault.donate, (1)));
    }

    function testRepeatDonationWithExistingPointsAndSurplusAtWalletGas() public {
        _approve(type(uint256).max);
        vm.prank(donor);
        vault.donate(1);
        vm.prank(donor);
        token.transfer(address(vault), 7e18);
        assertSameAtWalletGas(donor, address(vault), abi.encodeCall(vault.donate, (1.5e18)));
        assertEq(vault.giftCount(), 1);
        assertEq(vault.points(donor), 1);
    }

    function testEntireSupplyDonationAtWalletGas() public {
        uint256 supply = token.totalSupply();
        _approve(supply);
        assertSameAtWalletGas(donor, address(vault), abi.encodeCall(vault.donate, (supply)));
    }

    function testFinalClaimClearingOutstandingAndVaultBalanceAtWalletGas() public {
        _approve(1.5e18);
        vm.prank(donor);
        vault.donate(1.5e18);
        assertSameAtWalletGas(claimant, address(vault), abi.encodeCall(vault.claim, (1)));
        assertFalse(vault.isClaimed(1));
        assertEq(vault.totalOutstanding(), 1.5e18);
        assertEq(token.balanceOf(claimant), 0);
    }

    function testNonFinalClaimToFundedWalletAtWalletGas() public {
        _approve(type(uint256).max);
        vm.prank(donor);
        vault.donate(1.5e18);
        vm.prank(donor);
        vault.donate(1);
        vm.prank(donor);
        token.transfer(claimant, 1);
        assertSameAtWalletGas(claimant, address(vault), abi.encodeCall(vault.claim, (1)));
    }

    function testNoReturnTokenDonationAndClaimAtWalletGas() public {
        Token optional = new Token();
        DonationVault other = new DonationVault(address(optional));
        optional.mint(donor, 1.5e18);
        optional.setModes(Token.Mode.NoReturn, Token.Mode.NoReturn);
        vm.prank(donor);
        optional.approve(address(other), 1.5e18);
        assertSameAtWalletGas(donor, address(other), abi.encodeCall(other.donate, (1.5e18)));
        vm.prank(donor);
        other.donate(1.5e18);
        assertSameAtWalletGas(claimant, address(other), abi.encodeCall(other.claim, (1)));
    }

    function _approve(uint256 amount) private {
        vm.prank(donor);
        token.approve(address(vault), amount);
    }
}

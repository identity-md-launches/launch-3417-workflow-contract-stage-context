// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "../vendor/forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {DonationVault} from "../../src/DonationVault.sol";

/// @dev Closed system: all supply starts in four actors. Expected balances,
/// gifts, allowances and points are derived from successful action inputs,
/// never copied from the implementation's post-call getters.
contract DonationSequenceHandler is Test {
    struct ExpectedGift {
        address donor;
        uint256 amount;
        bool claimed;
    }

    uint256 public constant SUPPLY = 1_000_000_000e18;
    LaunchToken public immutable token;
    DonationVault public immutable vault;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => uint256) public donatedBy;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    ExpectedGift[] public gifts;
    uint256 public donated;
    uint256 public paid;
    uint256 public surplus;
    uint256 public successfulClaims;
    uint256 public rejectedCalls;

    // Sticky failure instead of reverting inside the handler: the default
    // invariant runner may ignore handler reverts. An unexpected call result
    // must survive until an invariant explicitly rejects it.
    bool public unexpectedResult;

    constructor(LaunchToken token_, DonationVault vault_) {
        token = token_;
        vault = vault_;
        for (uint256 i; i < actors.length; ++i) {
            address actor = makeAddr(string.concat("sequence actor ", vm.toString(i)));
            actors[i] = actor;
            expectedBalance[actor] = SUPPLY / actors.length;
        }
    }

    function giftCount() external view returns (uint256) {
        return gifts.length;
    }

    function donate(uint256 actorSeed, uint256 amountSeed, bool unlimited) external {
        address actor = _fundedActor(actorSeed);
        if (actor == address(0)) return;
        uint256 amount = _amount(amountSeed, expectedBalance[actor]);
        _donate(actor, amount, unlimited);
    }

    /// @dev Includes legitimate claims, donor self-claims, and repeat claims.
    function claim(uint256 giftSeed, uint256 actorSeed) external {
        if (gifts.length == 0) return;
        _claim(giftSeed % gifts.length, actors[actorSeed % actors.length]);
    }

    /// @dev Select an open gift so long sequences keep reaching actual payouts.
    function claimOpen(uint256 giftSeed, uint256 actorSeed) public {
        if (gifts.length == 0) return;
        uint256 start = giftSeed % gifts.length;
        for (uint256 i; i < gifts.length; ++i) {
            uint256 index = (start + i) % gifts.length;
            if (gifts[index].claimed) continue;
            _claim(index, _otherActor(actorSeed, gifts[index].donor));
            return;
        }
    }

    function unknownClaim(uint256 idSeed, uint256 actorSeed) external {
        uint256 id = idSeed % 2 == 0 ? 0 : bound(idSeed, gifts.length + 1, type(uint256).max);
        _reject(
            actors[actorSeed % actors.length],
            address(vault),
            abi.encodeCall(vault.claim, (id)),
            abi.encodeWithSelector(DonationVault.UnknownGift.selector, id)
        );
    }

    /// @dev Distinct failure causes remain available at every state.
    function invalidDonation(uint256 actorSeed, uint256 modeSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 mode = modeSeed % 3;
        uint256 amount;
        bytes memory errorData;
        if (mode == 0) {
            errorData = abi.encodeWithSelector(DonationVault.ZeroAmount.selector);
        } else if (mode == 1) {
            amount = expectedBalance[actor] + 1;
            if (!_approve(actor, address(vault), type(uint256).max)) return;
            errorData = abi.encodeWithSelector(DonationVault.TransferFailed.selector);
        } else {
            amount = bound(amountSeed, 1, SUPPLY);
            if (!_approve(actor, address(vault), amount - 1)) return;
            errorData = abi.encodeWithSelector(DonationVault.TransferFailed.selector);
        }
        _reject(actor, address(vault), abi.encodeCall(vault.donate, (amount)), errorData);
    }

    function directTransfer(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _fundedActor(actorSeed);
        if (actor == address(0)) return;
        uint256 amount = _amount(amountSeed, expectedBalance[actor]);
        if (!_success(
                actor, address(token), abi.encodeCall(token.transfer, (address(vault), amount)), abi.encode(true)
            )) {
            return;
        }
        expectedBalance[actor] -= amount;
        surplus += amount;
    }

    /// @dev Self-transfers and zero transfers are deliberately included.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        _transfer(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        uint256 spenderIndex = spenderSeed % (actors.length + 1);
        address spender = spenderIndex == actors.length ? address(vault) : actors[spenderIndex];
        _approve(owner, spender, amount);
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed, bool exceedLimit)
        external
    {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[from];
        uint256 allowed = expectedAllowance[from][spender];
        uint256 limit = balance < allowed ? balance : allowed;
        uint256 amount = exceedLimit ? limit + 1 : bound(amountSeed, 0, limit);
        bytes memory data = abi.encodeCall(token.transferFrom, (from, to, amount));
        if (allowed < amount) {
            _reject(
                spender,
                address(token),
                data,
                abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        } else if (balance < amount) {
            _reject(
                spender,
                address(token),
                data,
                abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, from, balance, amount)
            );
        } else if (_success(spender, address(token), data, abi.encode(true))) {
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
            if (allowed != type(uint256).max) expectedAllowance[from][spender] -= amount;
        }
    }

    /// @dev Donation -> eligible claim -> return of the exact tokens. Points
    /// persist, but repetition must never create tokens or rounding profit.
    function roundTrip(uint256 actorSeed, uint256 amountSeed) external {
        address donor = _fundedActor(actorSeed);
        if (donor == address(0)) return;
        address recipient = _otherActor(actorSeed, donor);
        uint256 amount = _amount(amountSeed, expectedBalance[donor]);
        uint256 before = token.balanceOf(donor);
        uint256 recipientBefore = token.balanceOf(recipient);
        if (!_donate(donor, amount, false)) return;
        if (!_claim(gifts.length - 1, recipient)) return;
        if (!_transfer(recipient, donor, amount)) return;
        if (token.balanceOf(donor) != before || token.balanceOf(recipient) != recipientBefore) unexpectedResult = true;
    }

    /// @dev Called by afterInvariant, not exposed to random action selection.
    function drain() external {
        for (uint256 i; i < gifts.length; ++i) {
            if (!gifts[i].claimed) _claim(i, _otherActor(i, gifts[i].donor));
        }
    }

    function _donate(address donor, uint256 amount, bool unlimited) private returns (bool) {
        uint256 allowance = unlimited ? type(uint256).max : amount;
        if (!_approve(donor, address(vault), allowance)) return false;
        uint256 id = gifts.length + 1;
        if (!_success(donor, address(vault), abi.encodeCall(vault.donate, (amount)), abi.encode(id))) return false;
        gifts.push(ExpectedGift(donor, amount, false));
        expectedBalance[donor] -= amount;
        donatedBy[donor] += amount;
        donated += amount;
        if (!unlimited) expectedAllowance[donor][address(vault)] -= amount;
        return true;
    }

    function _claim(uint256 index, address recipient) private returns (bool) {
        ExpectedGift storage gift = gifts[index];
        uint256 id = index + 1;
        bytes memory data = abi.encodeCall(vault.claim, (id));
        if (gift.claimed) {
            _reject(recipient, address(vault), data, abi.encodeWithSelector(DonationVault.AlreadyClaimed.selector, id));
            return false;
        }
        if (recipient == gift.donor) {
            _reject(recipient, address(vault), data, abi.encodeWithSelector(DonationVault.SelfClaim.selector, id));
            return false;
        }
        if (!_success(recipient, address(vault), data, abi.encode(gift.amount))) return false;
        gift.claimed = true;
        paid += gift.amount;
        expectedBalance[recipient] += gift.amount;
        ++successfulClaims;
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private returns (bool) {
        if (!_success(owner, address(token), abi.encodeCall(token.approve, (spender, amount)), abi.encode(true))) {
            return false;
        }
        expectedAllowance[owner][spender] = amount;
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private returns (bool) {
        if (!_success(from, address(token), abi.encodeCall(token.transfer, (to, amount)), abi.encode(true))) {
            return false;
        }
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        return true;
    }

    function _success(address actor, address target, bytes memory data, bytes memory expected) private returns (bool) {
        vm.prank(actor);
        (bool ok, bytes memory result) = target.call(data);
        if (!ok || keccak256(result) != keccak256(expected)) {
            unexpectedResult = true;
            return false;
        }
        return true;
    }

    function _reject(address actor, address target, bytes memory data, bytes memory expected) private {
        vm.prank(actor);
        (bool ok, bytes memory result) = target.call(data);
        if (ok || keccak256(result) != keccak256(expected)) unexpectedResult = true;
        else ++rejectedCalls;
    }

    function _fundedActor(uint256 seed) private view returns (address) {
        uint256 start = seed % actors.length;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[(start + i) % actors.length];
            if (expectedBalance[actor] > 0) return actor;
        }
        // A sequence can legitimately put the full supply into gifts or direct
        // transfers. Claims still run; never manufacture tokens to keep donating.
        return address(0);
    }

    function _otherActor(uint256 seed, address excluded) private view returns (address) {
        uint256 index = seed % actors.length;
        if (actors[index] == excluded) index = (index + 1) % actors.length;
        return actors[index];
    }

    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        uint256 choice = seed % 5;
        if (choice == 0) return 1;
        if (choice == 1) return maximum;
        if (choice == 2) return maximum < 1e18 - 1 ? maximum : 1e18 - 1;
        if (choice == 3) return maximum < 1e18 + 1 ? maximum : 1e18 + 1;
        return bound(seed, 1, maximum);
    }
}

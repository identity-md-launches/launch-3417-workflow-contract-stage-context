// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal local ERC-20 interface used by DonationVault.
interface IDonationToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title DonationVault
/// @notice Anyone can donate tokens as a gift; anyone other than the donor can claim a gift once.
///         Donors earn nontransferable points equal to the base units the vault received
///         (1e18 point units = 1 point = 1 whole token for an 18-decimal token).
///         Tokens sent directly to the vault (not via donate) earn no points and create no gift.
contract DonationVault {
    struct Gift {
        address donor;
        uint256 amount;
        bool claimed;
    }

    /// @notice The donated token, fixed at deployment.
    IDonationToken public immutable token;

    /// @notice Sum of amounts of all unclaimed gifts.
    uint256 public totalOutstanding;

    uint256 private _giftCount;
    mapping(uint256 => Gift) private _gifts;
    mapping(address => uint256) private _points;
    bool private _locked;

    event Donated(uint256 indexed giftId, address indexed donor, uint256 amount);
    event Claimed(uint256 indexed giftId, address indexed claimer, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NothingReceived();
    error UnknownGift(uint256 giftId);
    error AlreadyClaimed(uint256 giftId);
    error SelfClaim(uint256 giftId);
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address token_) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IDonationToken(token_);
    }

    /// @notice Pull `amount` base units from msg.sender (requires allowance) and record a gift.
    /// @return giftId Sequential gift ID, starting at 1.
    function donate(uint256 amount) external nonReentrant returns (uint256 giftId) {
        if (amount == 0) revert ZeroAmount();
        uint256 before = token.balanceOf(address(this));
        _safeCall(abi.encodeCall(IDonationToken.transferFrom, (msg.sender, address(this), amount)));
        uint256 received = token.balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();

        giftId = ++_giftCount;
        _gifts[giftId] = Gift({donor: msg.sender, amount: received, claimed: false});
        totalOutstanding += received;
        _points[msg.sender] += received;
        emit Donated(giftId, msg.sender, received);
    }

    /// @notice Claim the entire gift `giftId`. The donor cannot claim their own gift.
    function claim(uint256 giftId) external nonReentrant returns (uint256 amount) {
        Gift storage g = _gifts[giftId];
        if (g.donor == address(0)) revert UnknownGift(giftId);
        if (g.claimed) revert AlreadyClaimed(giftId);
        if (g.donor == msg.sender) revert SelfClaim(giftId);

        amount = g.amount;
        g.claimed = true;
        totalOutstanding -= amount;
        _safeCall(abi.encodeCall(IDonationToken.transfer, (msg.sender, amount)));
        emit Claimed(giftId, msg.sender, amount);
    }

    /// @notice Number of gifts created so far (IDs are 1..giftCount).
    function giftCount() external view returns (uint256) {
        return _giftCount;
    }

    function giftDonor(uint256 giftId) external view returns (address) {
        return _gifts[giftId].donor;
    }

    function giftAmount(uint256 giftId) external view returns (uint256) {
        return _gifts[giftId].amount;
    }

    function isClaimed(uint256 giftId) external view returns (bool) {
        return _gifts[giftId].claimed;
    }

    /// @notice Full gift record. Unknown IDs return (address(0), 0, false).
    function getGift(uint256 giftId) external view returns (address donor, uint256 amount, bool claimed) {
        Gift storage g = _gifts[giftId];
        return (g.donor, g.amount, g.claimed);
    }

    /// @notice Donor points of `account`, in token base units donated (nontransferable).
    function points(address account) external view returns (uint256) {
        return _points[account];
    }

    function _safeCall(bytes memory data) private {
        address t = address(token);
        if (t.code.length == 0) revert TransferFailed();
        (bool ok, bytes memory ret) = t.call(data);
        if (!ok || (ret.length != 0 && (ret.length < 32 || !abi.decode(ret, (bool))))) revert TransferFailed();
    }
}

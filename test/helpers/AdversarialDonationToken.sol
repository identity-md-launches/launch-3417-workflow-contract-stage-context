// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev A test-only ERC-20 with independent deposit/payout response modes.
/// Bad responses happen AFTER moving funds, so tests prove the vault rolls the
/// whole token call back, not merely that it rejects an error before any effects.
contract AdversarialDonationToken {
    enum Mode {
        Normal,
        NoReturn,
        FalseReturn,
        ShortReturn,
        NonBoolean,
        RevertCall,
        NoMovement,
        ExtendedTrue
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    Mode public depositMode;
    Mode public payoutMode;
    uint256 public shortLength = 1;
    uint256 public depositFeeBps;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnDeposit;
    bool public callbackOnPayout;
    bool public callbackArmed;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public callbackAttempts;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    error TokenRefused();

    function mint(address who, uint256 amount) external {
        balanceOf[who] += amount;
    }

    function setModes(Mode deposit, Mode payout) external {
        depositMode = deposit;
        payoutMode = payout;
    }

    function setShortLength(uint256 length) external {
        require(length > 0 && length < 32, "short ABI response only");
        shortLength = length;
    }

    function setDepositFee(uint256 bps) external {
        require(bps <= 10_000, "fee bounds");
        depositFeeBps = bps;
    }

    function armCallback(address target, bytes calldata data, bool deposit, bool payout) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnDeposit = deposit;
        callbackOnPayout = payout;
        callbackArmed = true;
        // A nested donation has real funds and approval, and would be possible
        // without the vault's lock. This avoids an attack that fails for no funds.
        allowance[address(this)][target] = type(uint256).max;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        require(approved >= amount, "allowance");
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        if (depositMode != Mode.NoMovement) {
            uint256 fee = amount * depositFeeBps / 10_000;
            _move(from, to, amount, fee);
        }
        if (callbackOnDeposit) _callback();
        return _respond(depositMode);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (payoutMode != Mode.NoMovement) _move(msg.sender, to, amount, 0);
        if (callbackOnPayout) _callback();
        return _respond(payoutMode);
    }

    function _move(address from, address to, uint256 amount, uint256 fee) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        emit Transfer(from, to, amount - fee);
        if (fee != 0) emit Transfer(from, address(0), fee);
    }

    function _callback() private {
        if (!callbackArmed) return;
        callbackArmed = false;
        ++callbackAttempts;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
    }

    function _respond(Mode mode) private view returns (bool) {
        if (mode == Mode.RevertCall) revert TokenRefused();
        if (mode == Mode.FalseReturn) return false;
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == Mode.ShortReturn) {
            uint256 length = shortLength;
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, length)
            }
        }
        if (mode == Mode.NonBoolean) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (mode == Mode.ExtendedTrue) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 123)
                return(0, 64)
            }
        }
        return true;
    }
}

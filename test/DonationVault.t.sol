// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DonationVault} from "../src/DonationVault.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert() external;
    function expectEmit(bool, bool, bool, bool) external;
}

/// @dev Local ERC-20 fixture with switchable failure modes.
contract MockToken {
    string public constant name = "test";
    string public constant symbol = "testAdam";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public returnFalseOnTransfer;
    bool public revertOnTransfer;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function setFail(bool returnFalse, bool doRevert) external {
        returnFalseOnTransfer = returnFalse;
        revertOnTransfer = doRevert;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (revertOnTransfer) revert("fail");
        if (returnFalseOnTransfer) return false;
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "allowance");
        allowance[f][msg.sender] = al - a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

contract DonationVaultTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event Donated(uint256 indexed giftId, address indexed donor, uint256 amount);
    event Claimed(uint256 indexed giftId, address indexed claimer, uint256 amount);

    MockToken token;
    DonationVault vault;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public {
        token = new MockToken();
        vault = new DonationVault(address(token));
        token.mint(alice, 1000e18);
        token.mint(bob, 1000e18);
        token.mint(carol, 1000e18);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    function _eq(uint256 a, uint256 b, string memory m) internal pure {
        require(a == b, m);
    }

    function _donate(address who, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return vault.donate(amt);
    }

    function _assertFunded() internal view {
        require(token.balanceOf(address(vault)) >= vault.totalOutstanding(), "underfunded");
    }

    function testConstructorRejectsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DonationVault.ZeroAddress.selector));
        new DonationVault(address(0));
    }

    function testDonateRecordsGiftAndPoints() public {
        vm.expectEmit(true, true, false, true);
        emit Donated(1, alice, 5e18);
        uint256 id = _donate(alice, 5e18);
        _eq(id, 1, "id");
        _eq(vault.giftCount(), 1, "count");
        require(vault.giftDonor(1) == alice, "donor");
        _eq(vault.giftAmount(1), 5e18, "amount");
        require(!vault.isClaimed(1), "claimed");
        _eq(vault.totalOutstanding(), 5e18, "outstanding");
        _eq(vault.points(alice), 5e18, "points");
        _eq(token.balanceOf(address(vault)), 5e18, "vault bal");
        _assertFunded();
    }

    function testMultipleGiftsAndDonors() public {
        _eq(_donate(alice, 1e18), 1, "id1");
        _eq(_donate(bob, 2e18), 2, "id2");
        _eq(_donate(alice, 3e18), 3, "id3");
        _eq(vault.giftCount(), 3, "count");
        _eq(vault.points(alice), 4e18, "alice pts");
        _eq(vault.points(bob), 2e18, "bob pts");
        _eq(vault.totalOutstanding(), 6e18, "outstanding");
        (address d, uint256 a, bool c) = vault.getGift(2);
        require(d == bob && a == 2e18 && !c, "gift2");
        _assertFunded();
    }

    function testFractionalAmounts() public {
        _donate(alice, 1);
        _donate(alice, 0.5e18);
        _eq(vault.points(alice), 0.5e18 + 1, "fractional points");
        _eq(vault.giftAmount(1), 1, "1 wei gift");
        vm.prank(carol);
        _eq(vault.claim(2), 0.5e18, "claim");
        _eq(token.balanceOf(carol), 1000.5e18, "carol bal");
        _eq(vault.totalOutstanding(), 1, "outstanding");
        _assertFunded();
    }

    function testZeroDonationReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.ZeroAmount.selector));
        vault.donate(0);
    }

    function test_RevertWhen_NoAllowance() public {
        vm.prank(carol); // carol has not approved
        vm.expectRevert(abi.encodeWithSelector(DonationVault.TransferFailed.selector));
        vault.donate(1e18);
        _eq(vault.giftCount(), 0, "no gift");
        _eq(vault.points(carol), 0, "no points");
    }

    function testInsufficientAllowanceReverts() public {
        vm.prank(carol);
        token.approve(address(vault), 1e18 - 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.TransferFailed.selector));
        vault.donate(1e18);
    }

    function testDirectTransferEarnsNoPoints() public {
        vm.prank(carol);
        token.transfer(address(vault), 7e18);
        _eq(vault.points(carol), 0, "points");
        _eq(vault.giftCount(), 0, "count");
        _eq(vault.totalOutstanding(), 0, "outstanding");
        _donate(alice, 1e18);
        _eq(vault.points(alice), 1e18, "only received credited");
        _assertFunded();
    }

    function testClaimPaysOnceAndPreservesPoints() public {
        _donate(alice, 4e18);
        vm.expectEmit(true, true, false, true);
        emit Claimed(1, bob, 4e18);
        vm.prank(bob);
        vault.claim(1);
        _eq(token.balanceOf(bob), 1004e18, "bob bal");
        require(vault.isClaimed(1), "claimed");
        _eq(vault.totalOutstanding(), 0, "outstanding");
        _eq(vault.points(alice), 4e18, "donor points kept");
        _eq(vault.points(bob), 0, "claimer no points");
        _assertFunded();
    }

    function testSelfClaimReverts() public {
        _donate(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.SelfClaim.selector, 1));
        vault.claim(1);
    }

    function testUnknownIdReverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.UnknownGift.selector, 0));
        vault.claim(0);
        _donate(alice, 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.UnknownGift.selector, 2));
        vault.claim(2);
    }

    function testRepeatClaimReverts() public {
        _donate(alice, 1e18);
        vm.prank(bob);
        vault.claim(1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.AlreadyClaimed.selector, 1));
        vault.claim(1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.AlreadyClaimed.selector, 1));
        vault.claim(1);
    }

    function test_RevertWhen_PayoutReturnsFalse() public {
        _donate(alice, 1e18);
        token.setFail(true, false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.TransferFailed.selector));
        vault.claim(1);
        require(!vault.isClaimed(1), "rolled back");
        _eq(vault.totalOutstanding(), 1e18, "outstanding");
        token.setFail(false, false);
        vm.prank(bob);
        vault.claim(1);
        require(vault.isClaimed(1), "claimed after recovery");
    }

    function test_RevertWhen_PayoutReverts() public {
        _donate(alice, 1e18);
        token.setFail(false, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DonationVault.TransferFailed.selector));
        vault.claim(1);
        require(!vault.isClaimed(1), "rolled back");
        _assertFunded();
    }

    function testOutstandingStaysFundedAcrossMixedFlow() public {
        _donate(alice, 10e18);
        _donate(bob, 3e18 + 7);
        _donate(alice, 1);
        vm.prank(carol);
        vault.claim(2);
        _assertFunded();
        vm.prank(bob);
        vault.claim(1);
        _assertFunded();
        _eq(vault.totalOutstanding(), 1, "outstanding");
        _eq(token.balanceOf(address(vault)), 1, "vault bal");
        _eq(vault.points(alice), 10e18 + 1, "alice pts");
        _eq(vault.points(bob), 3e18 + 7, "bob pts");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzDonateClaim(uint96 seed) public {
        // Generate a funded, nonzero donation for every input instead of
        // silently returning for almost the entire uint96 input space.
        uint256 amt = uint256(seed) % 1000e18 + 1;
        uint256 id = _donate(alice, amt);
        _eq(vault.points(alice), amt, "pts");
        _assertFunded();
        vm.prank(bob);
        vault.claim(id);
        _eq(vault.points(alice), amt, "pts kept");
        _eq(vault.totalOutstanding(), 0, "out");
    }
}

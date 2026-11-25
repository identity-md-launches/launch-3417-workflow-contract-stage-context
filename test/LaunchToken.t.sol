// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchToken} from "../src/LaunchToken.sol";

interface Vm {
    function prank(address sender) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
}

contract LaunchTokenTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    address private constant ALICE = address(0xA11CE);
    address private constant SPENDER = address(0xB0B);

    LaunchToken private token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new LaunchToken();
    }

    function testMetadataAndInitialAllocation() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        LaunchToken deployed = new LaunchToken();

        require(keccak256(bytes(deployed.name())) == keccak256("test"), "name");
        require(keccak256(bytes(deployed.symbol())) == keccak256("testAdam"), "symbol");
        require(deployed.decimals() == 18, "decimals");
        require(deployed.totalSupply() == SUPPLY, "supply");
        require(deployed.balanceOf(ALICE) == SUPPLY, "deployer allocation");
        require(deployed.balanceOf(address(this)) == 0, "other balance");
        require(deployed.balanceOf(address(0)) == 0, "zero balance");
    }

    function testFuzzTransferConservesSupply(uint256 seed) public {
        uint256 value = seed % (SUPPLY + 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, value);
        require(token.transfer(ALICE, value), "transfer");
        require(token.balanceOf(ALICE) == value, "recipient balance");
        require(token.balanceOf(address(this)) == SUPPLY - value, "sender balance");

        vm.prank(ALICE);
        require(token.transfer(ALICE, value), "self transfer");
        require(token.balanceOf(ALICE) == value, "self transfer balance");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    function testFuzzDelegatedSpend(uint256 approvalSeed, uint256 spendSeed) public {
        uint256 approved = approvalSeed % (SUPPLY + 1);
        uint256 spent = spendSeed % (approved + 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, approved);
        require(token.approve(SPENDER, approved), "approve");
        require(token.allowance(address(this), SPENDER) == approved, "approval stored");

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, spent);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, spent), "transferFrom");
        require(token.allowance(address(this), SPENDER) == approved - spent, "remaining allowance");
        require(token.balanceOf(ALICE) == spent, "recipient balance");
        require(token.balanceOf(address(this)) == SUPPLY - spent, "sender balance");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    function testFullSupplyTransferWithUnlimitedAllowanceAndRevocation() public {
        require(token.approve(SPENDER, type(uint256).max), "approve");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, SUPPLY), "transferFrom");
        require(token.balanceOf(ALICE) == SUPPLY, "recipient balance");
        require(token.balanceOf(address(this)) == 0, "sender balance");
        require(token.allowance(address(this), SPENDER) == type(uint256).max, "unlimited allowance");

        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 0);
        require(token.approve(SPENDER, 0), "revoke");
        require(token.allowance(address(this), SPENDER) == 0, "revocation stored");
    }

    function testZeroValueTransferFromWithoutAllowanceEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, address(this), 0);
        vm.prank(SPENDER);
        require(token.transferFrom(ALICE, address(this), 0), "zero transfer");
        require(token.balanceOf(address(this)) == SUPPLY, "recipient balance");
    }

    function testFuzzRejectsSpendAboveAllowance(uint256 seed) public {
        uint256 approved = seed % SUPPLY;
        require(token.approve(SPENDER, approved), "approve");

        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, SPENDER, approved, approved + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, approved + 1);

        require(token.allowance(address(this), SPENDER) == approved, "allowance changed");
        require(token.balanceOf(ALICE) == 0, "recipient balance changed");
    }

    function testRejectsSpendAboveBalanceAndPreservesAllowance() public {
        uint256 value = SUPPLY + 1;
        bytes memory reason =
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, value);
        vm.expectRevert(reason);
        token.transfer(ALICE, value);

        require(token.approve(SPENDER, value), "approve");
        vm.expectRevert(reason);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, value);
        require(token.allowance(address(this), SPENDER) == value, "allowance changed");
        require(token.balanceOf(address(this)) == SUPPLY, "sender balance changed");
    }

    function testRejectsZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);

        require(token.approve(SPENDER, 1), "approve");
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 1);
        require(token.allowance(address(this), SPENDER) == 1, "allowance changed");

        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);

        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }
}

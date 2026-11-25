// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchToken} from "../src/LaunchToken.sol";
import {DonationVault} from "../src/DonationVault.sol";

/// @dev Test-only factory: deploy both contracts in a single call without initialization calls.
contract ProjectFactoryHarness {
    function deploy() external returns (LaunchToken token, DonationVault vault) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        require(token.balanceOf(address(this)) == 1_000_000_000e18, "factory receives whole supply");
        vault = new DonationVault{salt: bytes32(uint256(2))}(address(token));
    }
}

contract ProjectLaunchTest {
    function testFactoryDeploysBothContractsWithoutInitialization() public {
        ProjectFactoryHarness factory = new ProjectFactoryHarness();
        (LaunchToken token, DonationVault vault) = factory.deploy();

        require(token.totalSupply() == 1_000_000_000e18, "policy supply");
        require(token.balanceOf(address(factory)) == token.totalSupply(), "factory retains whole supply");
        require(token.balanceOf(address(vault)) == 0, "vault receives no launch allocation");
        require(address(vault.token()) == address(token), "vault binds to launch token");
        require(vault.giftCount() == 0 && vault.totalOutstanding() == 0, "empty gift accounting");
        require(vault.points(address(factory)) == 0, "factory has no points");
        require(address(token).code.length > 0 && address(token).code.length <= 24_576, "token runtime size");
        require(address(vault).code.length > 0 && address(vault).code.length <= 24_576, "vault runtime size");
    }

    function testVaultConstructorAcceptsTokenAddressBeforeCodeExists() public {
        address futureToken = address(uint160(uint256(keccak256("future token for constructor test"))));
        require(futureToken.code.length == 0, "token has no code yet");
        DonationVault vault = new DonationVault(futureToken);

        require(address(vault.token()) == futureToken, "constructor stores token without calling it");
        require(vault.giftCount() == 0 && vault.totalOutstanding() == 0, "no constructor allocation");
        (bool ok,) = address(vault).call(abi.encodeCall(DonationVault.donate, (1)));
        require(!ok, "donation requires a live token");
        require(vault.giftCount() == 0 && vault.totalOutstanding() == 0, "failed use creates no gift");
        require(vault.points(address(this)) == 0, "failed use earns no points");
    }
}

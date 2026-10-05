// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Test-only minimal ERC-4337 v0.7 EntryPoint mock. Implements just the
/// deposit accounting the ArcPaymaster uses, plus a forwarder so tests can call
/// validatePaymasterUserOp with msg.sender == the entrypoint.
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

interface IArcPaymaster {
    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData);
}

contract MockEntryPoint {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _stakes;

    function depositTo(address account) external payable {
        _balances[account] += msg.value;
    }

    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external {
        _balances[msg.sender] -= withdrawAmount;
        (bool ok, ) = withdrawAddress.call{value: withdrawAmount}("");
        require(ok, "withdraw failed");
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function addStake(uint32) external payable {
        _stakes[msg.sender] += msg.value;
    }

    function unlockStake() external {}

    function withdrawStake(address payable withdrawAddress) external {
        uint256 amount = _stakes[msg.sender];
        _stakes[msg.sender] = 0;
        (bool ok, ) = withdrawAddress.call{value: amount}("");
        require(ok, "stake withdraw failed");
    }

    function stakeOf(address account) external view returns (uint256) {
        return _stakes[account];
    }

    function forwardValidate(address paymaster, PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData)
    {
        return IArcPaymaster(paymaster).validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    receive() external payable {}
}

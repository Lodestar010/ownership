// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title RegionalWallet — minimal regional sponsor wallet template
/// @notice Holds gas sponsorship funds for one region. Fully passive except for
/// a single logic-free blind `poke()` call to the RefillEscrow in its spend
/// flow. All refill decisions happen in the escrow, never here.
///
/// The blind poke uses try/catch so a failing poke can never break sponsorship:
/// the regional keeps spending from its existing balance regardless.
/// @dev This is a template for testnet. The production regional wallet will
/// wire into the paymaster deposit; the poke line stays exactly this simple.
interface IRefillEscrow {
    function poke(address regional) external;
}

contract RegionalWallet {
    IRefillEscrow public immutable escrow;
    address public immutable admin;

    event Sponsored(address indexed to, uint256 amount);
    event Funded(uint256 amount);

    error NotAdmin();
    error TransferFailed();

    constructor(address escrow_, address admin_) {
        escrow = IRefillEscrow(escrow_);
        admin = admin_;
    }

    /// @notice Sponsor a gas payment. The blind poke fires every time — no
    /// logic, no conditions, just a tap on the escrow's shoulder.
    function sponsor(address payable to, uint256 amount) external {
        if (msg.sender != admin) revert NotAdmin();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Sponsored(to, amount);
        // Blind poke: the escrow decides whether a refill is needed.
        // try/catch ensures a poke failure never blocks sponsorship.
        try escrow.poke(address(this)) {} catch {}
    }

    /// @notice Admin withdrawal (for rebalancing; timelock-gated in production).
    function withdraw(address payable to, uint256 amount) external {
        if (msg.sender != admin) revert NotAdmin();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {
        emit Funded(msg.value);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Local compilation stub so Hardhat builds the artifact for deployment scripts.
// The timelock itself is OpenZeppelin's TimelockController, used as the 7-day
// admin over every UUPS proxy in the naming service.
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

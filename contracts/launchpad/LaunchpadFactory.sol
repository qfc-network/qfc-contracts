// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./FairLaunch.sol";
import "./WhitelistSale.sol";
import "./DutchAuction.sol";

/**
 * @title LaunchpadFactory
 * @notice Factory for deploying and tracking launchpad contracts.
 */
contract LaunchpadFactory is Ownable {

    address[] public fairLaunches;
    address[] public whitelistSales;
    address[] public dutchAuctions;

    event FairLaunchDeployed(address indexed launch, address indexed deployer);
    event WhitelistSaleDeployed(address indexed sale, address indexed deployer);
    event DutchAuctionDeployed(address indexed auction, address indexed deployer);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Deploy a new FairLaunch contract.
     * @return addr The address of the deployed contract
     */
    function deployFairLaunch() external returns (address addr) {
        FairLaunch launch = new FairLaunch();
        launch.transferOwnership(msg.sender);
        addr = address(launch);
        fairLaunches.push(addr);
        emit FairLaunchDeployed(addr, msg.sender);
    }

    /**
     * @notice Deploy a new WhitelistSale contract.
     * @return addr The address of the deployed contract
     */
    function deployWhitelistSale() external returns (address addr) {
        WhitelistSale sale = new WhitelistSale();
        sale.transferOwnership(msg.sender);
        addr = address(sale);
        whitelistSales.push(addr);
        emit WhitelistSaleDeployed(addr, msg.sender);
    }

    /**
     * @notice Deploy a new DutchAuction contract.
     * @return addr The address of the deployed contract
     */
    function deployDutchAuction() external returns (address addr) {
        DutchAuction auction = new DutchAuction();
        auction.transferOwnership(msg.sender);
        addr = address(auction);
        dutchAuctions.push(addr);
        emit DutchAuctionDeployed(addr, msg.sender);
    }

    // --- View Functions ---

    function getFairLaunchCount() external view returns (uint256) {
        return fairLaunches.length;
    }

    function getWhitelistSaleCount() external view returns (uint256) {
        return whitelistSales.length;
    }

    function getDutchAuctionCount() external view returns (uint256) {
        return dutchAuctions.length;
    }

    function getAllFairLaunches() external view returns (address[] memory) {
        return fairLaunches;
    }

    function getAllWhitelistSales() external view returns (address[] memory) {
        return whitelistSales;
    }

    function getAllDutchAuctions() external view returns (address[] memory) {
        return dutchAuctions;
    }
}

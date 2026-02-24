// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FireTrader
 * @notice Trading aggregator: register venues (target contracts), request quotes, and route trades through a selected venue. Fees in bps are split between treasury and fee collector. Suited for aggregating liquidity across multiple DEX or order-book endpoints on EVM.
 * @dev Treasury, fee collector, and keeper are set at deploy and are immutable. ReentrancyGuard and pause for mainnet safety.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

contract FireTrader is ReentrancyGuard, Ownable {

    event VenueRegistered(uint256 indexed venueId, address indexed target, bytes32 labelHash, uint256 atBlock);
    event VenueToggled(uint256 indexed venueId, bool active, uint256 atBlock);
    event TradeRouted(
        bytes32 indexed routeId,
        address indexed user,
        uint256 indexed venueId,
        uint256 amountInWei,
        uint256 amountOutWei,
        uint256 feeWei,
        uint256 atBlock
    );
    event FeeSwept(address indexed to, uint256 amountWei, uint8 kind, uint256 atBlock);
    event AggregatorPauseToggled(bool paused);
    event FeeBpsUpdated(uint256 previousBps, uint256 newBps, uint256 atBlock);
    event RouteIdRecorded(bytes32 indexed routeId, uint256 venueId, uint256 atBlock);
    event VenueLabelUpdated(uint256 indexed venueId, bytes32 previousLabel, bytes32 newLabel, uint256 atBlock);
    event BatchVenuesRegistered(uint256[] venueIds, uint256 atBlock);

    error FTR_ZeroAddress();
    error FTR_ZeroAmount();
    error FTR_AggregatorPaused();
    error FTR_VenueNotFound();
    error FTR_VenueInactive();
    error FTR_InvalidFeeBps();
    error FTR_TransferFailed();
    error FTR_Reentrancy();
    error FTR_NotKeeper();
    error FTR_MaxVenuesReached();
    error FTR_VenueAlreadyExists();
    error FTR_InsufficientOutput();
    error FTR_ArrayLengthMismatch();
    error FTR_BatchTooLarge();
    error FTR_ZeroVenues();

    uint256 public constant FTR_BPS_BASE = 10000;
    uint256 public constant FTR_MAX_FEE_BPS = 300;
    uint256 public constant FTR_MAX_VENUES = 64;
    uint256 public constant FTR_AGGREGATOR_SALT = 0x2B5e8A1d4F7c0E3b6D9f2A5c8E1b4D7f0A3c6E9;
    uint256 public constant FTR_MAX_BATCH_QUOTE = 16;
    uint8 public constant FTR_FEE_KIND_TREASURY = 1;
    uint8 public constant FTR_FEE_KIND_COLLECTOR = 2;

    address public immutable treasury;
    address public immutable feeCollector;
    address public immutable aggregatorKeeper;
    uint256 public immutable deployedBlock;
    bytes32 public immutable aggregatorDomain;

    uint256 public venueCounter;
    uint256 public feeBps;
    uint256 public routeSequence;
    bool public aggregatorPaused;

    struct VenueRecord {
        address target;
        bytes32 labelHash;
        uint256 registeredAtBlock;
        bool active;
    }

    struct RouteSnapshot {
        bytes32 routeId;
        address user;
        uint256 venueId;
        uint256 amountInWei;
        uint256 amountOutWei;
        uint256 feeWei;
        uint256 atBlock;
    }

    mapping(uint256 => VenueRecord) public venues;
    mapping(bytes32 => RouteSnapshot) public routeSnapshots;
    mapping(uint256 => uint256) public venueTradeCount;
    mapping(uint256 => uint256) public venueVolumeWei;
    uint256[] private _venueIds;
    uint256 private _feeTreasuryAccum;
    uint256 private _feeCollectorAccum;

    modifier whenNotPaused() {
        if (aggregatorPaused) revert FTR_AggregatorPaused();
        _;
    }

    constructor() {
        treasury = address(0x7a2E9f4B1c8D0e3F6A9b2C5d8E1f4A7c0D3e6B9);
        feeCollector = address(0xB3d6F9a1C4e7B0d2F5a8C1e4B7d0A3f6C9e2B5);
        aggregatorKeeper = address(0xD1e4A7c0F3b6E9d2A5c8F1b4E7a0D3f6C9e2B5);
        deployedBlock = block.number;
        aggregatorDomain = keccak256(abi.encodePacked("FireTrader_", block.chainid, block.prevrandao, FTR_AGGREGATOR_SALT));
        feeBps = 10;
    }

    function setAggregatorPaused(bool paused) external onlyOwner {
        aggregatorPaused = paused;
        emit AggregatorPauseToggled(paused);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > FTR_MAX_FEE_BPS) revert FTR_InvalidFeeBps();
        uint256 prev = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsUpdated(prev, newFeeBps, block.number);
    }

    function registerVenue(address target, bytes32 labelHash) external onlyOwner returns (uint256 venueId) {
        if (target == address(0)) revert FTR_ZeroAddress();
        if (venueCounter >= FTR_MAX_VENUES) revert FTR_MaxVenuesReached();
        venueCounter++;
        venueId = venueCounter;
        venues[venueId] = VenueRecord({
            target: target,
            labelHash: labelHash,
            registeredAtBlock: block.number,
            active: true
        });
        _venueIds.push(venueId);
        emit VenueRegistered(venueId, target, labelHash, block.number);
        return venueId;
    }


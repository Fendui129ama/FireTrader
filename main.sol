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

    function setVenueActive(uint256 venueId, bool active) external onlyOwner {
        if (venues[venueId].target == address(0)) revert FTR_VenueNotFound();
        venues[venueId].active = active;
        emit VenueToggled(venueId, active, block.number);
    }

    function updateVenueLabel(uint256 venueId, bytes32 newLabelHash) external onlyOwner {
        if (venues[venueId].target == address(0)) revert FTR_VenueNotFound();
        bytes32 prev = venues[venueId].labelHash;
        venues[venueId].labelHash = newLabelHash;
        emit VenueLabelUpdated(venueId, prev, newLabelHash, block.number);
    }

    function registerVenuesBatch(address[] calldata targets, bytes32[] calldata labelHashes) external onlyOwner returns (uint256[] memory venueIds) {
        if (targets.length != labelHashes.length) revert FTR_ArrayLengthMismatch();
        if (targets.length > FTR_MAX_BATCH_QUOTE) revert FTR_BatchTooLarge();
        venueIds = new uint256[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) revert FTR_ZeroAddress();
            if (venueCounter >= FTR_MAX_VENUES) revert FTR_MaxVenuesReached();
            venueCounter++;
            uint256 vid = venueCounter;
            venues[vid] = VenueRecord({
                target: targets[i],
                labelHash: labelHashes[i],
                registeredAtBlock: block.number,
                active: true
            });
            _venueIds.push(vid);
            venueIds[i] = vid;
            emit VenueRegistered(vid, targets[i], labelHashes[i], block.number);
        }
        emit BatchVenuesRegistered(venueIds, block.number);
    }

    function routeTrade(
        uint256 venueId,
        uint256 minOutWei,
        bytes calldata payload
    ) external payable whenNotPaused nonReentrant returns (bytes32 routeId, uint256 amountOutWei) {
        VenueRecord storage v = venues[venueId];
        if (v.target == address(0)) revert FTR_VenueNotFound();
        if (!v.active) revert FTR_VenueInactive();
        if (msg.value == 0) revert FTR_ZeroAmount();

        uint256 feeWei = (msg.value * feeBps) / FTR_BPS_BASE;
        uint256 halfFee = feeWei / 2;
        _feeTreasuryAccum += halfFee;
        _feeCollectorAccum += (feeWei - halfFee);
        uint256 sentToVenue = msg.value - feeWei;

        (bool ok, bytes memory result) = v.target.call{value: sentToVenue}(payload);
        if (!ok) revert FTR_TransferFailed();
        if (result.length >= 32) {
            try abi.decode(result, (uint256)) returns (uint256 out) { amountOutWei = out; } catch { amountOutWei = 0; }
        } else {
            amountOutWei = 0;
        }
        if (minOutWei > 0 && amountOutWei < minOutWei) revert FTR_InsufficientOutput();

        routeSequence++;
        routeId = keccak256(abi.encodePacked(aggregatorDomain, msg.sender, venueId, msg.value, routeSequence, block.number));
        routeSnapshots[routeId] = RouteSnapshot({
            routeId: routeId,
            user: msg.sender,
            venueId: venueId,
            amountInWei: msg.value,
            amountOutWei: amountOutWei,
            feeWei: feeWei,
            atBlock: block.number
        });
        venueTradeCount[venueId]++;
        venueVolumeWei[venueId] += msg.value;
        emit TradeRouted(routeId, msg.sender, venueId, msg.value, amountOutWei, feeWei, block.number);
        emit RouteIdRecorded(routeId, venueId, block.number);
        return (routeId, amountOutWei);
    }

    function sweepTreasuryFees() external nonReentrant {
        if (msg.sender != treasury) revert FTR_NotKeeper();
        uint256 amount = _feeTreasuryAccum;
        if (amount == 0) revert FTR_ZeroAmount();
        _feeTreasuryAccum = 0;
        (bool sent,) = treasury.call{value: amount}("");
        if (!sent) revert FTR_TransferFailed();
        emit FeeSwept(treasury, amount, FTR_FEE_KIND_TREASURY, block.number);
    }

    function sweepCollectorFees() external nonReentrant {
        if (msg.sender != feeCollector) revert FTR_NotKeeper();
        uint256 amount = _feeCollectorAccum;
        if (amount == 0) revert FTR_ZeroAmount();
        _feeCollectorAccum = 0;
        (bool sent,) = feeCollector.call{value: amount}("");
        if (!sent) revert FTR_TransferFailed();
        emit FeeSwept(feeCollector, amount, FTR_FEE_KIND_COLLECTOR, block.number);
    }

    function getVenue(uint256 venueId) external view returns (
        address target,
        bytes32 labelHash,
        uint256 registeredAtBlock,
        bool active
    ) {
        VenueRecord storage v = venues[venueId];
        return (v.target, v.labelHash, v.registeredAtBlock, v.active);
    }

    function getVenueIds() external view returns (uint256[] memory) {
        return _venueIds;
    }

    function getActiveVenueIds() external view returns (uint256[] memory ids) {
        uint256 n = 0;
        for (uint256 i = 0; i < _venueIds.length; i++) {
            if (venues[_venueIds[i]].active) n++;
        }
        ids = new uint256[](n);
        n = 0;
        for (uint256 i = 0; i < _venueIds.length; i++) {
            if (venues[_venueIds[i]].active) ids[n++] = _venueIds[i];
        }
    }

    function getRouteSnapshot(bytes32 routeId) external view returns (
        address user,
        uint256 venueId,
        uint256 amountInWei,
        uint256 amountOutWei,
        uint256 feeWei,
        uint256 atBlock
    ) {
        RouteSnapshot storage r = routeSnapshots[routeId];
        return (r.user, r.venueId, r.amountInWei, r.amountOutWei, r.feeWei, r.atBlock);
    }

    function getFeeTreasuryAccum() external view returns (uint256) {
        return _feeTreasuryAccum;
    }

    function getFeeCollectorAccum() external view returns (uint256) {
        return _feeCollectorAccum;
    }

    function getConfig() external view returns (
        address treasury_,
        address feeCollector_,
        address aggregatorKeeper_,
        uint256 feeBps_,
        uint256 deployedBlock_,
        bool aggregatorPaused_
    ) {
        return (treasury, feeCollector, aggregatorKeeper, feeBps, deployedBlock, aggregatorPaused);
    }

    function getVenueTradeCount(uint256 venueId) external view returns (uint256) {
        return venueTradeCount[venueId];
    }

    function getVenueVolumeWei(uint256 venueId) external view returns (uint256) {
        return venueVolumeWei[venueId];
    }

    function isVenueActive(uint256 venueId) external view returns (bool) {
        return venues[venueId].active && venues[venueId].target != address(0);
    }

    function totalVenues() external view returns (uint256) {
        return venueCounter;
    }

    function nextRouteSequence() external view returns (uint256) {
        return routeSequence + 1;
    }

    function getAggregatorDomain() external view returns (bytes32) {
        return aggregatorDomain;
    }

    struct VenueView {
        uint256 venueId;
        address target;
        bytes32 labelHash;
        uint256 registeredAtBlock;
        bool active;
        uint256 tradeCount;
        uint256 volumeWei;
    }

    function getVenueView(uint256 venueId) external view returns (VenueView memory v) {
        VenueRecord storage vr = venues[venueId];
        if (vr.target == address(0)) return v;
        v.venueId = venueId;
        v.target = vr.target;
        v.labelHash = vr.labelHash;
        v.registeredAtBlock = vr.registeredAtBlock;
        v.active = vr.active;
        v.tradeCount = venueTradeCount[venueId];
        v.volumeWei = venueVolumeWei[venueId];
    }

    function getVenueViewBatch(uint256[] calldata venueIds) external view returns (VenueView[] memory out) {
        out = new VenueView[](venueIds.length);
        for (uint256 i = 0; i < venueIds.length; i++) {
            VenueRecord storage vr = venues[venueIds[i]];
            if (vr.target == address(0)) continue;
            out[i] = VenueView({
                venueId: venueIds[i],
                target: vr.target,
                labelHash: vr.labelHash,
                registeredAtBlock: vr.registeredAtBlock,
                active: vr.active,
                tradeCount: venueTradeCount[venueIds[i]],
                volumeWei: venueVolumeWei[venueIds[i]]
            });
        }
    }

    function getVenuesPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 len = _venueIds.length;
        if (offset >= len) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 size = end - offset;
        ids = new uint256[](size);
        for (uint256 i = 0; i < size; i++) ids[i] = _venueIds[offset + i];
    }

    function getTreasury() external view returns (address) { return treasury; }
    function getFeeCollector() external view returns (address) { return feeCollector; }
    function getAggregatorKeeper() external view returns (address) { return aggregatorKeeper; }
    function getDeployedBlock() external view returns (uint256) { return deployedBlock; }
    function getFeeBps() external view returns (uint256) { return feeBps; }
    function getRouteSequence() external view returns (uint256) { return routeSequence; }
    function isPaused() external view returns (bool) { return aggregatorPaused; }
    function bpsBase() external pure returns (uint256) { return FTR_BPS_BASE; }
    function maxFeeBps() external pure returns (uint256) { return FTR_MAX_FEE_BPS; }
    function maxVenues() external pure returns (uint256) { return FTR_MAX_VENUES; }
    function aggregatorSalt() external pure returns (uint256) { return FTR_AGGREGATOR_SALT; }

    function computeFeeForAmount(uint256 amountWei) external view returns (uint256 feeWei) {
        return (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function computeAmountAfterFee(uint256 amountWei) external view returns (uint256) {
        return amountWei - (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function getVenueTarget(uint256 venueId) external view returns (address) {
        return venues[venueId].target;
    }

    function getVenueLabel(uint256 venueId) external view returns (bytes32) {
        return venues[venueId].labelHash;
    }

    function getVenueRegisteredBlock(uint256 venueId) external view returns (uint256) {
        return venues[venueId].registeredAtBlock;
    }

    function getTotalFeeTreasury() external view returns (uint256) {
        return _feeTreasuryAccum;
    }

    function getTotalFeeCollector() external view returns (uint256) {
        return _feeCollectorAccum;
    }

    function getTotalFeesAccumulated() external view returns (uint256) {
        return _feeTreasuryAccum + _feeCollectorAccum;
    }

    function getRouteUser(bytes32 routeId) external view returns (address) {
        return routeSnapshots[routeId].user;
    }

    function getRouteVenueId(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].venueId;
    }

    function getRouteAmountIn(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].amountInWei;
    }

    function getRouteAmountOut(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].amountOutWei;
    }

    function getRouteFeeWei(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].feeWei;
    }

    function getRouteAtBlock(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].atBlock;
    }

    function hasRoute(bytes32 routeId) external view returns (bool) {
        return routeSnapshots[routeId].atBlock != 0;
    }

    function venueCount() external view returns (uint256) {
        return venueCounter;
    }

    function configTreasury() external view returns (address) { return treasury; }
    function configFeeCollector() external view returns (address) { return feeCollector; }
    function configKeeper() external view returns (address) { return aggregatorKeeper; }
    function configFeeBps() external view returns (uint256) { return feeBps; }
    function configDeployedBlock() external view returns (uint256) { return deployedBlock; }
    function configPaused() external view returns (bool) { return aggregatorPaused; }

    function getConstants() external pure returns (
        uint256 bpsBase,
        uint256 maxFeeBps,
        uint256 maxVenues,
        uint256 maxBatchQuote
    ) {
        return (FTR_BPS_BASE, FTR_MAX_FEE_BPS, FTR_MAX_VENUES, FTR_MAX_BATCH_QUOTE);
    }

    function getConfigSnapshot() external view returns (
        address treasury_,
        address feeCollector_,
        address keeper_,
        uint256 feeBps_,
        uint256 deployedBlock_,
        uint256 venueCounter_,
        uint256 routeSequence_,
        bool paused_
    ) {
        return (treasury, feeCollector, aggregatorKeeper, feeBps, deployedBlock, venueCounter, routeSequence, aggregatorPaused);
    }

    function totalVolumeAcrossVenues() external view returns (uint256 total) {
        for (uint256 i = 0; i < _venueIds.length; i++) total += venueVolumeWei[_venueIds[i]];
    }

    function totalTradesAcrossVenues() external view returns (uint256 total) {
        for (uint256 i = 0; i < _venueIds.length; i++) total += venueTradeCount[_venueIds[i]];
    }

    function getFeeSplit(uint256 amountWei) external view returns (uint256 toTreasury, uint256 toCollector) {
        uint256 fee = (amountWei * feeBps) / FTR_BPS_BASE;
        toTreasury = fee / 2;
        toCollector = fee - toTreasury;
    }

    function estimateFee(uint256 amountWei) external view returns (uint256) {
        return (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function estimateAmountToVenue(uint256 amountWei) external view returns (uint256) {
        return amountWei - (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function getVenueIdsRange(uint256 fromId, uint256 toId) external view returns (uint256[] memory ids) {
        if (fromId > toId || toId > venueCounter) return new uint256[](0);
        uint256 size = toId - fromId + 1;
        ids = new uint256[](size);
        for (uint256 i = 0; i < size; i++) ids[i] = fromId + i;
    }

    function isVenueRegistered(uint256 venueId) external view returns (bool) {
        return venues[venueId].target != address(0);
    }

    function getActiveVenueCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < _venueIds.length; i++) {
            if (venues[_venueIds[i]].active) count++;
        }
    }

    function feeKindTreasury() external pure returns (uint8) { return FTR_FEE_KIND_TREASURY; }
    function feeKindCollector() external pure returns (uint8) { return FTR_FEE_KIND_COLLECTOR; }

    function getVenueAtIndex(uint256 index) external view returns (uint256) {
        return _venueIds[index];
    }

    function getVenueIdsLength() external view returns (uint256) {
        return _venueIds.length;
    }

    function getAllVenueViews() external view returns (VenueView[] memory out) {
        out = new VenueView[](_venueIds.length);
        for (uint256 i = 0; i < _venueIds.length; i++) {
            uint256 vid = _venueIds[i];
            VenueRecord storage vr = venues[vid];
            out[i] = VenueView({
                venueId: vid,
                target: vr.target,
                labelHash: vr.labelHash,
                registeredAtBlock: vr.registeredAtBlock,
                active: vr.active,
                tradeCount: venueTradeCount[vid],
                volumeWei: venueVolumeWei[vid]
            });
        }
    }

    function getRouteSnapshotFull(bytes32 routeId) external view returns (
        bytes32 id,
        address user,
        uint256 venueId,
        uint256 amountInWei,
        uint256 amountOutWei,
        uint256 feeWei,
        uint256 atBlock
    ) {
        RouteSnapshot storage r = routeSnapshots[routeId];
        return (r.routeId, r.user, r.venueId, r.amountInWei, r.amountOutWei, r.feeWei, r.atBlock);
    }

    function treasuryAccumulated() external view returns (uint256) {
        return _feeTreasuryAccum;
    }

    function collectorAccumulated() external view returns (uint256) {
        return _feeCollectorAccum;
    }

    function domainHash() external view returns (bytes32) {
        return aggregatorDomain;
    }

    function sequenceNumber() external view returns (uint256) {
        return routeSequence;
    }

    function venueTarget(uint256 venueId) external view returns (address) {
        return venues[venueId].target;
    }

    function venueLabel(uint256 venueId) external view returns (bytes32) {
        return venues[venueId].labelHash;
    }

    function venueRegisteredBlock(uint256 venueId) external view returns (uint256) {
        return venues[venueId].registeredAtBlock;
    }

    function venueActive(uint256 venueId) external view returns (bool) {
        return venues[venueId].active;
    }

    function venueTrades(uint256 venueId) external view returns (uint256) {
        return venueTradeCount[venueId];
    }

    function venueVolume(uint256 venueId) external view returns (uint256) {
        return venueVolumeWei[venueId];
    }

    function routeUser(bytes32 routeId) external view returns (address) {
        return routeSnapshots[routeId].user;
    }

    function routeVenueId(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].venueId;
    }

    function routeAmountIn(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].amountInWei;
    }

    function routeAmountOut(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].amountOutWei;
    }

    function routeFee(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].feeWei;
    }

    function routeBlock(bytes32 routeId) external view returns (uint256) {
        return routeSnapshots[routeId].atBlock;
    }

    function computeRouteId(address user, uint256 venueId, uint256 amountWei, uint256 seq) external view returns (bytes32) {
        return keccak256(abi.encodePacked(aggregatorDomain, user, venueId, amountWei, seq, block.number));
    }

    function computeRouteIdSimple(uint256 venueId, uint256 amountWei) external view returns (bytes32) {
        return keccak256(abi.encodePacked(aggregatorDomain, msg.sender, venueId, amountWei, routeSequence + 1, block.number));
    }

    function getVenueIdsFromTo(uint256 fromIdx, uint256 toIdx) external view returns (uint256[] memory ids) {
        if (fromIdx > toIdx || toIdx >= _venueIds.length) return new uint256[](0);
        uint256 size = toIdx - fromIdx + 1;
        ids = new uint256[](size);
        for (uint256 i = 0; i < size; i++) ids[i] = _venueIds[fromIdx + i];
    }

    function getActiveVenueIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] memory active = this.getActiveVenueIds();
        uint256 len = active.length;
        if (offset >= len) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 size = end - offset;
        ids = new uint256[](size);
        for (uint256 i = 0; i < size; i++) ids[i] = active[offset + i];
    }

    function getFeeForAmountWei(uint256 amountWei) external view returns (uint256) {
        return (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function getAmountToVenueAfterFee(uint256 amountWei) external view returns (uint256) {
        return amountWei - (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function getConfigTreasury() external view returns (address) { return treasury; }
    function getConfigFeeCollector() external view returns (address) { return feeCollector; }
    function getConfigKeeper() external view returns (address) { return aggregatorKeeper; }
    function getConfigFeeBps() external view returns (uint256) { return feeBps; }
    function getConfigDeployedBlock() external view returns (uint256) { return deployedBlock; }
    function getConfigPaused() external view returns (bool) { return aggregatorPaused; }

    function supportsVenue(uint256 venueId) external view returns (bool) {
        return venues[venueId].target != address(0);
    }

    function getVenueViewByIndex(uint256 index) external view returns (VenueView memory) {
        uint256 vid = _venueIds[index];
        VenueRecord storage vr = venues[vid];
        return VenueView({
            venueId: vid,
            target: vr.target,
            labelHash: vr.labelHash,
            registeredAtBlock: vr.registeredAtBlock,
            active: vr.active,
            tradeCount: venueTradeCount[vid],
            volumeWei: venueVolumeWei[vid]
        });
    }

    function getMultipleVenueTargets(uint256[] calldata venueIds) external view returns (address[] memory targets) {
        targets = new address[](venueIds.length);
        for (uint256 i = 0; i < venueIds.length; i++) targets[i] = venues[venueIds[i]].target;
    }

    function getMultipleVenueActive(uint256[] calldata venueIds) external view returns (bool[] memory actives) {
        actives = new bool[](venueIds.length);
        for (uint256 i = 0; i < venueIds.length; i++) actives[i] = venues[venueIds[i]].active && venues[venueIds[i]].target != address(0);
    }

    function getMultipleVenueVolume(uint256[] calldata venueIds) external view returns (uint256[] memory volumes) {
        volumes = new uint256[](venueIds.length);
        for (uint256 i = 0; i < venueIds.length; i++) volumes[i] = venueVolumeWei[venueIds[i]];
    }

    function getMultipleVenueTradeCount(uint256[] calldata venueIds) external view returns (uint256[] memory counts) {
        counts = new uint256[](venueIds.length);
        for (uint256 i = 0; i < venueIds.length; i++) counts[i] = venueTradeCount[venueIds[i]];
    }

    function bpsDenom() external pure returns (uint256) { return FTR_BPS_BASE; }
    function maxFeeBpsConstant() external pure returns (uint256) { return FTR_MAX_FEE_BPS; }
    function maxVenuesConstant() external pure returns (uint256) { return FTR_MAX_VENUES; }
    function aggregatorSaltConstant() external pure returns (uint256) { return FTR_AGGREGATOR_SALT; }
    function maxBatchQuoteConstant() external pure returns (uint256) { return FTR_MAX_BATCH_QUOTE; }

    function totalVolume() external view returns (uint256) {
        return this.totalVolumeAcrossVenues();
    }

    function totalTrades() external view returns (uint256) {
        return this.totalTradesAcrossVenues();
    }

    function estimateFeeWei(uint256 amountWei) external view returns (uint256) {
        return (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function estimateNetToVenue(uint256 amountWei) external view returns (uint256) {
        return amountWei - (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function getVenueInfo(uint256 venueId) external view returns (
        address targetAddr,
        bytes32 labelHashVal,
        uint256 registeredBlock,
        bool isActive,
        uint256 tradesCount,
        uint256 volumeTotalWei
    ) {
        VenueRecord storage vr = venues[venueId];
        return (vr.target, vr.labelHash, vr.registeredAtBlock, vr.active, venueTradeCount[venueId], venueVolumeWei[venueId]);
    }

    function getRouteInfo(bytes32 routeId) external view returns (
        address userAddr,
        uint256 venueIdVal,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeWeiVal,
        uint256 blockNum
    ) {
        RouteSnapshot storage r = routeSnapshots[routeId];
        return (r.user, r.venueId, r.amountInWei, r.amountOutWei, r.feeWei, r.atBlock);
    }

    function getConstantsFull() external pure returns (
        uint256 bpsBaseVal,
        uint256 maxFeeBpsVal,
        uint256 maxVenuesVal,
        uint256 maxBatchQuoteVal,
        uint256 saltVal
    ) {
        return (FTR_BPS_BASE, FTR_MAX_FEE_BPS, FTR_MAX_VENUES, FTR_MAX_BATCH_QUOTE, FTR_AGGREGATOR_SALT);
    }

    function venueExists(uint256 venueId) external view returns (bool) {
        return venues[venueId].target != address(0);
    }

    function routeExists(bytes32 routeId) external view returns (bool) {
        return routeSnapshots[routeId].atBlock != 0;
    }

    function getFirstVenueId() external view returns (uint256) {
        return _venueIds.length > 0 ? _venueIds[0] : 0;
    }

    function getLastVenueId() external view returns (uint256) {
        return _venueIds.length > 0 ? _venueIds[_venueIds.length - 1] : 0;
    }

    function getFeeAccumulatedTreasury() external view returns (uint256) {
        return _feeTreasuryAccum;
    }

    function getFeeAccumulatedCollector() external view returns (uint256) {
        return _feeCollectorAccum;
    }

    function getTotalFees() external view returns (uint256) {
        return _feeTreasuryAccum + _feeCollectorAccum;
    }

    function getVenueList() external view returns (uint256[] memory) {
        return _venueIds;
    }

    function getVenueRecord(uint256 venueId) external view returns (
        address targetAddr,
        bytes32 label,
        uint256 registeredBlock,
        bool isActive
    ) {
        VenueRecord storage vr = venues[venueId];
        return (vr.target, vr.labelHash, vr.registeredAtBlock, vr.active);
    }

    function getRouteRecord(bytes32 routeId) external view returns (
        address userAddr,
        uint256 venueIdVal,
        uint256 amountInWei,
        uint256 amountOutWei,
        uint256 feeWeiVal,
        uint256 atBlockNum
    ) {
        RouteSnapshot storage r = routeSnapshots[routeId];
        return (r.user, r.venueId, r.amountInWei, r.amountOutWei, r.feeWei, r.atBlock);
    }

    function computeFee(uint256 amountWei) external view returns (uint256) {
        return (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function computeNet(uint256 amountWei) external view returns (uint256) {
        return amountWei - (amountWei * feeBps) / FTR_BPS_BASE;
    }

    function getVenueIdsList() external view returns (uint256[] memory) {
        return _venueIds;
    }

    function activeVenueCount() external view returns (uint256) {
        return this.getActiveVenueCount();
    }

    function totalVolumeWei() external view returns (uint256) {
        return this.totalVolumeAcrossVenues();
    }

    function totalTradeCount() external view returns (uint256) {
        return this.totalTradesAcrossVenues();
    }

    function treasuryFees() external view returns (uint256) {
        return _feeTreasuryAccum;
    }

    function collectorFees() external view returns (uint256) {
        return _feeCollectorAccum;
    }

    function domain() external view returns (bytes32) {
        return aggregatorDomain;
    }

    function nextSequence() external view returns (uint256) {
        return routeSequence + 1;
    }

    function getVenueByIndex(uint256 index) external view returns (uint256) {
        return _venueIds[index];
    }

    function getVenueCount() external view returns (uint256) {
        return _venueIds.length;
    }

    function getRouteSnapshotStruct(bytes32 routeId) external view returns (RouteSnapshot memory) {
        return routeSnapshots[routeId];
    }

    function getVenueViewStruct(uint256 venueId) external view returns (VenueView memory) {
        return this.getVenueView(venueId);
    }

    function getVenueViewsForIds(uint256[] calldata ids) external view returns (VenueView[] memory) {
        return this.getVenueViewBatch(ids);
    }

    function feeTreasury() external view returns (uint256) {
        return _feeTreasuryAccum;
    }

    function feeCollectorAccum() external view returns (uint256) {
        return _feeCollectorAccum;
    }

    function aggregatorDomainBytes() external view returns (bytes32) {
        return aggregatorDomain;
    }

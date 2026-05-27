// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {DataService} from "@graphprotocol/horizon/data-service/DataService.sol";
import {DataServiceFees} from "@graphprotocol/horizon/data-service/extensions/DataServiceFees.sol";
import {
    DataServicePausableUpgradeable
} from "@graphprotocol/horizon/data-service/extensions/DataServicePausableUpgradeable.sol";
import {IGraphPayments} from "@graphprotocol/interfaces/contracts/horizon/IGraphPayments.sol";
import {IGraphTallyCollector} from "@graphprotocol/interfaces/contracts/horizon/IGraphTallyCollector.sol";

import {ICampDataService} from "./interfaces/ICampDataService.sol";

/// @title CampDataService
/// @notice Experimental Arbitrum data service built on The Graph Protocol's Horizon framework.
///
/// Camp exposes decoded Arbitrum One blockchain data (ERC-20 transfers, decoded protocol
/// events, raw SQL queries) via a REST API backed by a self-hosted Amp node. This contract
/// makes that Amp node a paid Horizon provider: consumers deposit GRT into PaymentsEscrow,
/// each query carries a signed TAP receipt, and providers collect fees via collect().
///
/// @dev DISCLAIMER: This is an experimental community project. It is not affiliated with
///      or endorsed by The Graph Foundation or Edge & Node.
///
/// @dev Inherits DataService (provision utilities, GraphDirectory), DataServiceFees
///      (stake-backed fee locking), DataServicePausableUpgradeable (emergency stop).
///      Deployed as a UUPS upgradeable proxy on Arbitrum Sepolia (testnet).
contract CampDataService is
    OwnableUpgradeable,
    UUPSUpgradeable,
    DataService,
    DataServiceFees,
    DataServicePausableUpgradeable,
    ICampDataService
{
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Minimum GRT provision per registered provider.
    uint256 public constant MIN_PROVISION = 555e18;

    /// @notice 1% of collected fees burned (in PPM: 1% = 10_000).
    uint256 public constant BURN_CUT_PPM = 10_000;

    /// @notice 1% retained by the data service as revenue (in PPM).
    uint256 public constant DATA_SERVICE_CUT_PPM = 10_000;

    /// @notice Absolute lower bound on the thawing period.
    uint64 public constant MIN_THAWING_PERIOD = 14 days;

    /// @notice Stake locked per GRT of fees collected. Matches SubgraphService.
    uint256 public constant STAKE_TO_FEES_RATIO = 5;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Whether a provider has registered with this service.
    mapping(address => bool) public registeredProviders;

    /// @notice Address that receives collected GRT for each provider.
    /// @dev Defaults to the provider address. Use setPaymentsDestination to separate
    ///      the hot signing key from a cold payment wallet.
    mapping(address => address) public paymentsDestination;

    /// @notice Service registrations per provider (active and historical).
    mapping(address => ServiceRegistration[]) internal _serviceRegs;

    /// @notice GraphTallyCollector used to redeem TAP receipts on-chain.
    IGraphTallyCollector private immutable GRAPH_TALLY_COLLECTOR;

    /// @notice Governance-adjustable thawing period (lower-bounded by MIN_THAWING_PERIOD).
    uint64 public minThawingPeriod;

    /// @dev Reserved storage slots for future upgrades.
    uint256[50] private __gap;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @dev Sets immutables and locks the implementation against direct initialisation.
    /// @param controller The Graph Protocol controller address.
    /// @param graphTallyCollector Address of the deployed GraphTallyCollector.
    constructor(address controller, address graphTallyCollector) DataService(controller) {
        GRAPH_TALLY_COLLECTOR = IGraphTallyCollector(graphTallyCollector);
        _disableInitializers();
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /// @notice Initialise the proxy. Called exactly once via ERC1967Proxy deployment.
    /// @param owner_ Initial owner (governance multisig or deployer).
    /// @param pauseGuardian Address authorised to pause the service in an emergency.
    function initialize(address owner_, address pauseGuardian) external initializer {
        __Ownable_init(owner_);
        __DataService_init();
        __DataServicePausable_init();

        minThawingPeriod = MIN_THAWING_PERIOD;
        _setProvisionTokensRange(MIN_PROVISION, type(uint256).max);
        _setThawingPeriodRange(MIN_THAWING_PERIOD, type(uint64).max);
        _setVerifierCutRange(0, uint32(1_000_000));
        _setPauseGuardian(pauseGuardian, true);
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // -------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------

    /// @inheritdoc ICampDataService
    function setMinThawingPeriod(uint64 period) external onlyOwner {
        if (period < MIN_THAWING_PERIOD) revert ThawingPeriodTooShort(MIN_THAWING_PERIOD, period);
        minThawingPeriod = period;
        emit MinThawingPeriodSet(period);
    }

    /// @inheritdoc ICampDataService
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero address");
        _graphToken().transfer(to, amount);
        emit FeesWithdrawn(to, amount);
    }

    /// @notice Grant or revoke pause guardian status.
    function setPauseGuardian(address guardian, bool allowed) external onlyOwner {
        _setPauseGuardian(guardian, allowed);
    }

    // -------------------------------------------------------------------------
    // IDataService — provider lifecycle
    // -------------------------------------------------------------------------

    /// @notice Register as a Camp data provider.
    /// @param serviceProvider The provider's address.
    /// @param data ABI-encoded (string endpoint, string geoHash, address paymentsDestination).
    ///        endpoint — base URL of the provider's camp-gateway instance
    ///        geoHash  — geohash of the provider's location (for latency routing)
    function register(address serviceProvider, bytes calldata data)
        external
        override
        whenNotPaused
    {
        _requireAuthorizedForProvision(serviceProvider);
        if (registeredProviders[serviceProvider]) {
            revert ProviderAlreadyRegistered(serviceProvider);
        }

        _checkProvisionTokens(serviceProvider);
        _checkProvisionParameters(serviceProvider, false);

        (string memory endpoint, string memory geoHash, address dest) =
            abi.decode(data, (string, string, address));

        registeredProviders[serviceProvider] = true;
        paymentsDestination[serviceProvider] = dest == address(0) ? serviceProvider : dest;

        emit ProviderRegistered(serviceProvider, endpoint, geoHash);
    }

    /// @notice Deregister. All active services must be stopped first.
    /// @dev Not in IDataService — no override keyword.
    function deregister(address serviceProvider, bytes calldata)
        external
    {
        _requireAuthorizedForProvision(serviceProvider);
        if (!registeredProviders[serviceProvider]) revert ProviderNotRegistered(serviceProvider);
        if (activeServiceCount(serviceProvider) > 0) revert ActiveServicesExist(serviceProvider);

        registeredProviders[serviceProvider] = false;
        emit ProviderDeregistered(serviceProvider);
    }

    /// @inheritdoc ICampDataService
    function setPaymentsDestination(address destination) external {
        if (!registeredProviders[msg.sender]) revert ProviderNotRegistered(msg.sender);
        address dest = destination == address(0) ? msg.sender : destination;
        paymentsDestination[msg.sender] = dest;
        emit PaymentsDestinationSet(msg.sender, dest);
    }

    /// @notice Activate data service for a specific tier.
    /// @param serviceProvider The provider's address.
    /// @param data ABI-encoded (DataTier tier, string endpoint).
    function startService(address serviceProvider, bytes calldata data)
        external
        override
        whenNotPaused
    {
        _requireAuthorizedForProvision(serviceProvider);
        if (!registeredProviders[serviceProvider]) revert ProviderNotRegistered(serviceProvider);

        (DataTier tier, string memory endpoint) = abi.decode(data, (DataTier, string));

        // Reuse an existing (stopped) slot for this tier to keep the array bounded.
        ServiceRegistration[] storage regs = _serviceRegs[serviceProvider];
        for (uint256 i = 0; i < regs.length; i++) {
            if (regs[i].tier == tier) {
                regs[i].endpoint = endpoint;
                regs[i].active   = true;
                emit ServiceStarted(serviceProvider, tier, endpoint);
                return;
            }
        }

        regs.push(ServiceRegistration({ tier: tier, endpoint: endpoint, active: true }));
        emit ServiceStarted(serviceProvider, tier, endpoint);
    }

    /// @notice Deactivate data service for a specific tier.
    /// @param serviceProvider The provider's address.
    /// @param data ABI-encoded (DataTier tier).
    function stopService(address serviceProvider, bytes calldata data)
        external
        override
    {
        _requireAuthorizedForProvision(serviceProvider);
        DataTier tier = abi.decode(data, (DataTier));

        ServiceRegistration[] storage regs = _serviceRegs[serviceProvider];
        for (uint256 i = 0; i < regs.length; i++) {
            if (regs[i].tier == tier && regs[i].active) {
                regs[i].active = false;
                emit ServiceStopped(serviceProvider, tier);
                return;
            }
        }
        revert RegistrationNotFound(serviceProvider, tier);
    }

    /// @notice Collect fees by submitting a signed Receipt Aggregate Voucher (RAV).
    ///
    /// Flow:
    ///   CampDataService.collect() → GraphTallyCollector.collect()
    ///     → PaymentsEscrow.collect() → GraphPayments.collect()
    ///     → distributes: protocol tax → data service cut → delegator cut → provider
    ///
    /// @param serviceProvider The provider collecting fees.
    /// @param paymentType Must be QueryFee.
    /// @param data ABI-encoded (SignedRAV, tokensToCollect).
    /// @return fees Total GRT collected.
    function collect(address serviceProvider, IGraphPayments.PaymentTypes paymentType, bytes calldata data)
        external
        override
        whenNotPaused
        returns (uint256 fees)
    {
        if (paymentType != IGraphPayments.PaymentTypes.QueryFee) revert InvalidPaymentType();
        if (!registeredProviders[serviceProvider]) revert ProviderNotRegistered(serviceProvider);

        (IGraphTallyCollector.SignedRAV memory signedRav, uint256 tokensToCollect) =
            abi.decode(data, (IGraphTallyCollector.SignedRAV, uint256));

        if (signedRav.rav.serviceProvider != serviceProvider) {
            revert InvalidServiceProvider(serviceProvider, signedRav.rav.serviceProvider);
        }

        // Release expired stake claims before locking new ones.
        _releaseStake(serviceProvider, 0);

        // Collect via GraphTallyCollector → PaymentsEscrow → GraphPayments.
        // 2% routed to this contract: 1% burned, 1% retained as revenue.
        uint256 balanceBefore = _graphToken().balanceOf(address(this));
        fees = GRAPH_TALLY_COLLECTOR.collect(
            paymentType,
            abi.encode(signedRav, BURN_CUT_PPM + DATA_SERVICE_CUT_PPM, paymentsDestination[serviceProvider]),
            tokensToCollect
        );

        uint256 received = _graphToken().balanceOf(address(this)) - balanceBefore;
        if (received > 0) {
            uint256 burned = received * BURN_CUT_PPM / (BURN_CUT_PPM + DATA_SERVICE_CUT_PPM);
            _graphToken().burn(burned);
            emit FeesBurned(serviceProvider, burned);
        }

        if (fees > 0) {
            // Lock stake proportional to fees — released after the dispute window.
            _lockStake(serviceProvider, fees * STAKE_TO_FEES_RATIO, block.timestamp + minThawingPeriod);
        }
    }

    /// @notice Slash is not implemented — this service has no on-chain dispute mechanism.
    function slash(address, bytes calldata) external pure override {
        revert("slashing not supported");
    }

    /// @notice Accept pending provision parameter changes.
    function acceptProvisionPendingParameters(address serviceProvider, bytes calldata)
        external
        override
    {
        _requireAuthorizedForProvision(serviceProvider);
        _acceptProvisionParameters(serviceProvider);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc ICampDataService
    function isRegistered(address provider) external view returns (bool) {
        return registeredProviders[provider];
    }

    /// @inheritdoc ICampDataService
    function getServiceRegistrations(address provider)
        external
        view
        returns (ServiceRegistration[] memory)
    {
        return _serviceRegs[provider];
    }

    /// @inheritdoc ICampDataService
    function activeServiceCount(address provider) public view returns (uint256 count) {
        ServiceRegistration[] storage regs = _serviceRegs[provider];
        for (uint256 i = 0; i < regs.length; i++) {
            if (regs[i].active) count++;
        }
    }
}

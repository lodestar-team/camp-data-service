// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

/// @title ICampDataService
/// @notice Interface for the Camp data service on The Graph Protocol's Horizon framework.
///
/// Camp exposes decoded Arbitrum One blockchain data (transfers, events, blocks, decoded
/// protocol tables) via a REST API backed by a self-hosted Amp node. This contract turns
/// that Amp node into a paid Horizon provider: consumers deposit GRT into PaymentsEscrow,
/// each request carries a signed TAP receipt, and providers collect fees hourly via collect().
///
/// Provider lifecycle:
///   provision → register → startService (per tier) → [collect]* → stopService → deregister
interface ICampDataService {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Data tiers determine what endpoints a provider offers.
    enum DataTier {
        BASIC,   // 0 — raw lookups: status, block, tx, address queries
        DECODED, // 1 — decoded protocol data: transfers, events, horizon, uniswap-v3
        SQL      // 2 — raw SQL queries (POST /v1/sql)
    }

    /// @notice Active or historical service registration for a provider.
    struct ServiceRegistration {
        DataTier tier;
        string   endpoint;
        bool     active;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ProviderRegistered(
        address indexed provider,
        string  endpoint,
        string  geoHash
    );

    event ProviderDeregistered(address indexed provider);

    event PaymentsDestinationSet(
        address indexed provider,
        address indexed destination
    );

    event ServiceStarted(
        address indexed provider,
        DataTier        tier,
        string          endpoint
    );

    event ServiceStopped(
        address indexed provider,
        DataTier        tier
    );

    event MinThawingPeriodSet(uint64 period);

    event FeesBurned(address indexed provider, uint256 amount);

    event FeesWithdrawn(address indexed to, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ProviderAlreadyRegistered(address provider);
    error ProviderNotRegistered(address provider);
    error ActiveServicesExist(address provider);
    error RegistrationNotFound(address provider, DataTier tier);
    error InvalidServiceProvider(address expected, address actual);
    error InvalidPaymentType();
    error ThawingPeriodTooShort(uint64 required, uint64 actual);

    // -------------------------------------------------------------------------
    // Provider operations
    // -------------------------------------------------------------------------

    /// @notice Update the address that receives collected GRT fees.
    function setPaymentsDestination(address destination) external;

    // -------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------

    /// @notice Update the minimum thawing period (lower-bounded by MIN_THAWING_PERIOD).
    function setMinThawingPeriod(uint64 period) external;

    /// @notice Withdraw accumulated data-service revenue to `to`.
    function withdrawFees(address to, uint256 amount) external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function isRegistered(address provider) external view returns (bool);

    function getServiceRegistrations(address provider)
        external
        view
        returns (ServiceRegistration[] memory);

    function activeServiceCount(address provider) external view returns (uint256);

    function paymentsDestination(address provider) external view returns (address);

    function minThawingPeriod() external view returns (uint64);
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CampDataService} from "../src/CampDataService.sol";
import {ICampDataService} from "../src/interfaces/ICampDataService.sol";
import {IGraphPayments} from "@graphprotocol/interfaces/contracts/horizon/IGraphPayments.sol";
import {IGraphTallyCollector} from "@graphprotocol/interfaces/contracts/horizon/IGraphTallyCollector.sol";
import {IHorizonStaking} from "@graphprotocol/interfaces/contracts/horizon/IHorizonStaking.sol";
import {ControllerMock} from "@graphprotocol/horizon/mocks/ControllerMock.sol";

contract CampDataServiceTest is Test {
    // ── deployment handles ────────────────────────────────────────────────────
    CampDataService impl;
    CampDataService ds; // proxy

    ControllerMock controller;

    // ── actors ────────────────────────────────────────────────────────────────
    address owner          = makeAddr("owner");
    address pauseGuardian  = makeAddr("pauseGuardian");
    address provider       = makeAddr("provider");
    address operator       = makeAddr("operator");
    address payDest        = makeAddr("payDest");
    address graphTallyCollector = makeAddr("graphTallyCollector");

    // ── mocked Horizon contract addresses ────────────────────────────────────
    address grtToken;
    address staking;
    address graphPayments;
    address paymentsEscrow;
    address epochManager;
    address rewardsManager;
    address tokenGateway;
    address proxyAdmin;

    string constant ENDPOINT = "https://camp.example.com";
    string constant GEOHASH  = "u1hx";

    // ── setUp ─────────────────────────────────────────────────────────────────

    function setUp() public {
        grtToken       = makeAddr("grtToken");
        staking        = makeAddr("staking");
        graphPayments  = makeAddr("graphPayments");
        paymentsEscrow = makeAddr("paymentsEscrow");
        epochManager   = makeAddr("epochManager");
        rewardsManager = makeAddr("rewardsManager");
        tokenGateway   = makeAddr("tokenGateway");
        proxyAdmin     = makeAddr("proxyAdmin");

        controller = new ControllerMock(owner);
        controller.setContractProxy(keccak256("GraphToken"),        grtToken);
        controller.setContractProxy(keccak256("Staking"),           staking);
        controller.setContractProxy(keccak256("GraphPayments"),     graphPayments);
        controller.setContractProxy(keccak256("PaymentsEscrow"),    paymentsEscrow);
        controller.setContractProxy(keccak256("EpochManager"),      epochManager);
        controller.setContractProxy(keccak256("RewardsManager"),    rewardsManager);
        controller.setContractProxy(keccak256("GraphTokenGateway"), tokenGateway);
        controller.setContractProxy(keccak256("GraphProxyAdmin"),   proxyAdmin);

        impl = new CampDataService(address(controller), graphTallyCollector);
        bytes memory initData = abi.encodeCall(CampDataService.initialize, (owner, pauseGuardian));
        ds = CampDataService(address(new ERC1967Proxy(address(impl), initData)));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// Mock HorizonStaking.isAuthorized so `caller` is authorised for `sp`.
    function _mockAuthorized(address sp, address caller) internal {
        // HorizonStaking.isAuthorized(serviceProvider, verifier, operator)
        vm.mockCall(
            staking,
            abi.encodeWithSignature("isAuthorized(address,address,address)", sp, address(ds), caller),
            abi.encode(true)
        );
    }

    /// Mock HorizonStaking.getProvision to return a valid provision >= MIN_PROVISION.
    function _mockProvision(address sp) internal {
        IHorizonStaking.Provision memory p;
        p.tokens         = ds.MIN_PROVISION();
        p.thawingPeriod  = uint64(14 days);
        p.maxVerifierCut = uint32(1_000_000);
        p.createdAt      = uint64(block.timestamp); // must be non-zero — ProvisionManager checks this
        vm.mockCall(
            staking,
            abi.encodeWithSignature("getProvision(address,address)", sp, address(ds)),
            abi.encode(p)
        );
    }

    function _register(address sp, address caller) internal {
        _mockAuthorized(sp, caller);
        _mockProvision(sp);
        vm.prank(caller);
        ds.register(sp, abi.encode(ENDPOINT, GEOHASH, address(0)));
    }

    function _startService(address sp, address caller, ICampDataService.DataTier tier) internal {
        _mockAuthorized(sp, caller);
        vm.prank(caller);
        ds.startService(sp, abi.encode(tier, ENDPOINT));
    }

    function _stopService(address sp, address caller, ICampDataService.DataTier tier) internal {
        _mockAuthorized(sp, caller);
        vm.prank(caller);
        ds.stopService(sp, abi.encode(tier));
    }

    // ── register ─────────────────────────────────────────────────────────────

    function test_register_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ICampDataService.ProviderRegistered(provider, ENDPOINT, GEOHASH);
        _register(provider, operator);
    }

    function test_register_setsRegistered() public {
        _register(provider, operator);
        assertTrue(ds.isRegistered(provider));
    }

    function test_register_defaultsPaymentDest_toProvider() public {
        _register(provider, operator);
        assertEq(ds.paymentsDestination(provider), provider);
    }

    function test_register_setsCustomPaymentDest() public {
        _mockAuthorized(provider, operator);
        _mockProvision(provider);
        vm.prank(operator);
        ds.register(provider, abi.encode(ENDPOINT, GEOHASH, payDest));
        assertEq(ds.paymentsDestination(provider), payDest);
    }

    function test_register_revertsIfAlreadyRegistered() public {
        _register(provider, operator);
        _mockAuthorized(provider, operator);
        _mockProvision(provider);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ICampDataService.ProviderAlreadyRegistered.selector, provider)
        );
        ds.register(provider, abi.encode(ENDPOINT, GEOHASH, address(0)));
    }

    // ── setPaymentsDestination ────────────────────────────────────────────────

    function test_setPaymentsDestination() public {
        _register(provider, operator);
        vm.prank(provider);
        ds.setPaymentsDestination(payDest);
        assertEq(ds.paymentsDestination(provider), payDest);
    }

    function test_setPaymentsDestination_revertsIfNotRegistered() public {
        vm.prank(provider);
        vm.expectRevert(
            abi.encodeWithSelector(ICampDataService.ProviderNotRegistered.selector, provider)
        );
        ds.setPaymentsDestination(payDest);
    }

    // ── startService ─────────────────────────────────────────────────────────

    function test_startService_basic() public {
        _register(provider, operator);
        vm.expectEmit(true, false, false, true);
        emit ICampDataService.ServiceStarted(provider, ICampDataService.DataTier.BASIC, ENDPOINT);
        _startService(provider, operator, ICampDataService.DataTier.BASIC);
    }

    function test_startService_allTiers() public {
        _register(provider, operator);
        _startService(provider, operator, ICampDataService.DataTier.BASIC);
        _startService(provider, operator, ICampDataService.DataTier.DECODED);
        _startService(provider, operator, ICampDataService.DataTier.SQL);
        assertEq(ds.activeServiceCount(provider), 3);
    }

    function test_startService_reusesSameSlot() public {
        _register(provider, operator);
        _startService(provider, operator, ICampDataService.DataTier.BASIC);
        _stopService(provider, operator, ICampDataService.DataTier.BASIC);

        string memory newEndpoint = "https://camp2.example.com";
        _mockAuthorized(provider, operator);
        vm.prank(operator);
        ds.startService(provider, abi.encode(ICampDataService.DataTier.BASIC, newEndpoint));

        ICampDataService.ServiceRegistration[] memory regs = ds.getServiceRegistrations(provider);
        assertEq(regs.length, 1, "should reuse existing slot");
        assertTrue(regs[0].active);
    }

    function test_startService_revertsIfNotRegistered() public {
        _mockAuthorized(provider, operator);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ICampDataService.ProviderNotRegistered.selector, provider)
        );
        ds.startService(provider, abi.encode(ICampDataService.DataTier.BASIC, ENDPOINT));
    }

    // ── stopService ──────────────────────────────────────────────────────────

    function test_stopService() public {
        _register(provider, operator);
        _startService(provider, operator, ICampDataService.DataTier.BASIC);

        vm.expectEmit(true, false, false, true);
        emit ICampDataService.ServiceStopped(provider, ICampDataService.DataTier.BASIC);
        _stopService(provider, operator, ICampDataService.DataTier.BASIC);

        assertEq(ds.activeServiceCount(provider), 0);
    }

    function test_stopService_revertsIfNotActive() public {
        _register(provider, operator);
        _mockAuthorized(provider, operator);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICampDataService.RegistrationNotFound.selector,
                provider,
                ICampDataService.DataTier.BASIC
            )
        );
        ds.stopService(provider, abi.encode(ICampDataService.DataTier.BASIC));
    }

    // ── deregister ───────────────────────────────────────────────────────────

    function test_deregister() public {
        _register(provider, operator);
        _mockAuthorized(provider, operator);
        vm.prank(operator);
        ds.deregister(provider, "");
        assertFalse(ds.isRegistered(provider));
    }

    function test_deregister_revertsWithActiveServices() public {
        _register(provider, operator);
        _startService(provider, operator, ICampDataService.DataTier.BASIC);

        _mockAuthorized(provider, operator);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ICampDataService.ActiveServicesExist.selector, provider)
        );
        ds.deregister(provider, "");
    }

    function test_deregister_revertsIfNotRegistered() public {
        _mockAuthorized(provider, operator);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ICampDataService.ProviderNotRegistered.selector, provider)
        );
        ds.deregister(provider, "");
    }

    // ── collect ───────────────────────────────────────────────────────────────

    function test_collect_revertsForNonQueryFeePaymentType() public {
        _register(provider, operator);
        // IGraphPayments.PaymentTypes.IndexingFee = 1
        vm.expectRevert(ICampDataService.InvalidPaymentType.selector);
        ds.collect(provider, IGraphPayments.PaymentTypes.IndexingFee, "");
    }

    function test_collect_revertsIfNotRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(ICampDataService.ProviderNotRegistered.selector, provider)
        );
        ds.collect(provider, IGraphPayments.PaymentTypes.QueryFee, "");
    }

    function test_collect_revertsOnServiceProviderMismatch() public {
        _register(provider, operator);

        address wrongProvider = makeAddr("wrongProvider");
        IGraphTallyCollector.ReceiptAggregateVoucher memory rav;
        rav.serviceProvider = wrongProvider; // mismatch
        IGraphTallyCollector.SignedRAV memory signedRav;
        signedRav.rav = rav;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICampDataService.InvalidServiceProvider.selector,
                provider,
                wrongProvider
            )
        );
        ds.collect(provider, IGraphPayments.PaymentTypes.QueryFee, abi.encode(signedRav, uint256(0)));
    }

    // ── governance ───────────────────────────────────────────────────────────

    function test_setMinThawingPeriod() public {
        uint64 newPeriod = 30 days;
        vm.prank(owner);
        ds.setMinThawingPeriod(newPeriod);
        assertEq(ds.minThawingPeriod(), newPeriod);
    }

    function test_setMinThawingPeriod_revertsIfTooShort() public {
        uint64 minPeriod = ds.MIN_THAWING_PERIOD(); // read before setting up prank
        vm.expectRevert(
            abi.encodeWithSelector(ICampDataService.ThawingPeriodTooShort.selector, minPeriod, 1 days)
        );
        vm.prank(owner);
        ds.setMinThawingPeriod(1 days);
    }

    function test_setMinThawingPeriod_revertsIfNotOwner() public {
        vm.prank(provider);
        vm.expectRevert();
        ds.setMinThawingPeriod(30 days);
    }

    // ── pause ─────────────────────────────────────────────────────────────────

    function test_pauseGuardian_canPause() public {
        vm.prank(pauseGuardian);
        ds.pause();
        assertTrue(ds.paused());
    }

    function test_register_revertsWhenPaused() public {
        vm.prank(pauseGuardian);
        ds.pause();

        _mockAuthorized(provider, operator);
        _mockProvision(provider);
        vm.prank(operator);
        vm.expectRevert();
        ds.register(provider, abi.encode(ENDPOINT, GEOHASH, address(0)));
    }

    // ── UUPS upgrade ──────────────────────────────────────────────────────────

    function test_upgrade_revertsIfNotOwner() public {
        address newImpl = address(new CampDataService(address(controller), graphTallyCollector));
        vm.prank(provider);
        vm.expectRevert();
        ds.upgradeToAndCall(newImpl, "");
    }

    function test_upgrade_ownerCanUpgrade() public {
        address newImpl = address(new CampDataService(address(controller), graphTallyCollector));
        vm.prank(owner);
        ds.upgradeToAndCall(newImpl, "");
    }

    // ── constants ────────────────────────────────────────────────────────────

    function test_constants() public view {
        assertEq(ds.MIN_PROVISION(),        555e18);
        assertEq(ds.BURN_CUT_PPM(),         10_000);
        assertEq(ds.DATA_SERVICE_CUT_PPM(), 10_000);
        assertEq(ds.MIN_THAWING_PERIOD(),   14 days);
        assertEq(ds.STAKE_TO_FEES_RATIO(),  5);
    }
}

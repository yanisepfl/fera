// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

/// @notice Stage-3 (contracts/VAULT_STRATEGY_V3.md §10): exercises `script/Deploy.s.sol` end-to-end
///         — instantiate + `run()`, exactly as `forge script` would broadcast it — against a fully
///         stubbed `.env`, and asserts:
///          - every precompute-address `_eq` assertion inside the script itself passes (if any
///            offset were wrong — e.g. GenesisVesting disturbing the n+1..n+9 offsets or the
///            DEPLOY-1 EsFera/Distributor/EmissionsController 3-cycle — `run()` would revert on
///            its own; this test additionally confirms every resulting address carries real code);
///          - the genesis 10% mint lands on `GenesisVesting` (locked), NOT on the treasury EOA
///            directly, and `GenesisVesting`'s beneficiary/token are wired to the real deploy
///            addresses;
///          - `RevenueDistributor.treasury` is the PLAIN EOA (`FERA_TREASURY_EOA`) — this deploy
///            never constructs a `Treasury.sol` instance at all.
contract DeployScriptTest is Test {
    Deploy internal d;

    uint256 internal constant DEPLOYER_PK = 0xA11CE;
    address internal deployer;

    address internal poolManager = makeAddr("poolManager");
    address internal timelock = makeAddr("timelock");
    address internal emissionsKeeper = makeAddr("emissionsKeeper");
    address internal rootPoster = makeAddr("rootPoster");
    address internal vaultKeeper = makeAddr("vaultKeeper");
    address internal opsSink = makeAddr("opsSink");
    address internal treasuryEoa = makeAddr("treasuryEoa");
    address internal weth = makeAddr("weth");
    address internal usdg = makeAddr("usdg");

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        vm.deal(deployer, 100 ether);

        vm.setEnv("FERA_POOL_MANAGER", vm.toString(poolManager));
        vm.setEnv("FERA_TIMELOCK_SAFE", vm.toString(timelock));
        vm.setEnv("FERA_EMISSIONS_KEEPER_SAFE", vm.toString(emissionsKeeper));
        vm.setEnv("FERA_ROOT_POSTER_SAFE", vm.toString(rootPoster));
        vm.setEnv("FERA_VAULT_KEEPER", vm.toString(vaultKeeper));
        vm.setEnv("FERA_OPS_SINK", vm.toString(opsSink));
        vm.setEnv("FERA_TREASURY_EOA", vm.toString(treasuryEoa));
        vm.setEnv("FERA_WETH", vm.toString(weth));
        vm.setEnv("FERA_USDG", vm.toString(usdg));
        vm.setEnv("FERA_DEPLOYER_PK", vm.toString(DEPLOYER_PK));

        d = new Deploy();
    }

    function test_run_wiresGenesisVestingToRealFeraTokenAndTreasuryEoa() public {
        d.run();

        assertEq(
            address(d.genesisVesting().token()), address(d.feraToken()), "GenesisVesting.token must be the real FeraToken"
        );
        assertEq(d.genesisVesting().beneficiary(), treasuryEoa, "GenesisVesting.beneficiary must be FERA_TREASURY_EOA");

        // The genesis 10% landed on GenesisVesting, NOT on the treasury EOA directly (item 2/3).
        uint256 expectedGenesis = (FeraConstants.FERA_MAX_SUPPLY * FeraConstants.GENESIS_TREASURY_BPS) / FeraConstants.BPS;
        assertEq(
            d.feraToken().balanceOf(address(d.genesisVesting())), expectedGenesis, "genesis mint must land on GenesisVesting"
        );
        assertEq(d.feraToken().balanceOf(treasuryEoa), 0, "treasury EOA must NOT receive the genesis mint unlocked");

        // Nothing claimable yet — deploy just happened, still well before the 1yr cliff.
        assertEq(d.genesisVesting().releasable(), 0, "nothing should be claimable immediately at deploy");
    }

    function test_run_revenueDistributorTreasuryIsThePlainEoa_neverTreasurySol() public {
        d.run();

        assertEq(d.revDist().treasury(), treasuryEoa, "RevenueDistributor.treasury must be the configured plain EOA");
        assertEq(treasuryEoa.code.length, 0, "treasury must stay a plain EOA (no bytecode), no Treasury.sol deployed");
    }

    function test_run_allPrecomputedAddressesCarryRealCode() public {
        d.run();
        // The script's own `_eq(...)` calls already enforce the offsets internally (run() would
        // have reverted on a mismatch) — this additionally confirms every resulting address is a
        // real, deployed contract (not an EOA stand-in / precompute miscount landing on empty code).
        assertGt(address(d.genesisVesting()).code.length, 0, "genesisVesting must have code");
        assertGt(address(d.feraToken()).code.length, 0, "feraToken must have code");
        assertGt(address(d.shareImpl()).code.length, 0, "shareImpl must have code");
        assertGt(address(d.anchor()).code.length, 0, "anchor must have code");
        assertGt(address(d.revDist()).code.length, 0, "revDist must have code");
        assertGt(address(d.esFera()).code.length, 0, "esFera must have code");
        assertGt(address(d.emissions()).code.length, 0, "emissions must have code");
        assertGt(address(d.distributor()).code.length, 0, "distributor must have code");
        assertGt(address(d.vault()).code.length, 0, "vault must have code");
        assertGt(address(d.hook()).code.length, 0, "hook must have code");
    }

    function test_run_deploy1CycleStillResolvesCorrectly() public {
        d.run();
        // DEPLOY-1 3-cycle (EsFera -> Distributor -> EmissionsController -> EsFera) must still
        // resolve exactly as before GenesisVesting took over the n+0 offset.
        assertEq(address(d.esFera().minter()), address(d.distributor()), "EsFera.minter must be the Distributor");
        assertEq(address(d.distributor().controller()), address(d.emissions()), "Distributor.controller must be EmissionsController");
        assertEq(d.feraToken().emissionsController(), address(d.emissions()), "FeraToken's sole minter must be EmissionsController");
    }

    function test_run_hookVaultWiringStillValid() public {
        d.run();
        assertEq(address(d.hook().vault()), address(d.vault()), "hook<->vault wiring");
        assertEq(address(d.vault().hook()), address(d.hook()), "vault<->hook wiring");
    }
}

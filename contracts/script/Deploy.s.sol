// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────────────────────────────────
// FERA mainnet/testnet deploy — Agent 5 (Deployment/DevOps).
//
// COMPILE-ORIENTED SKELETON. This was authored to mirror the exact constructor signatures in
// contracts/src as of 2026-07-12 (verified by hand). It was NOT `forge build`-compiled in the
// authoring environment (ANTI-HANG: no long builds were run). Treat the first CI `forge build` of
// this file as the compile gate. Anything tagged `// TODO(chain-confirm)` is a D-7-gated external
// immutable that MUST be flipped VERIFIED via CHAIN.md §8 before a mainnet run.
//
// WHY THIS FILE EXISTS — the DEPLOY-1 cycle. Three sets of contracts hold their peers as
// `immutable` constructor args and reference each other cyclically:
//   (A) AnchorStaking ↔ RevenueDistributor              (2-cycle)
//   (B) EsFera → Distributor → EmissionsController → EsFera   (3-cycle, DEPLOY-1)
//   (C) FeraVault ↔ FeraHook                             (2-cycle; hook also flag-mined)
// A mutual *constructor-arg* cycle CANNOT be closed by plain CREATE2, because each contract's
// CREATE2 address is a function of its init-code (which embeds the counterparty address) — a
// fixed point with no resolvable order. The resolution used here is **nonce-based CREATE address
// precompute from a single dedicated deployer**: addr = keccak(rlp(deployer, nonce)), which is
// independent of constructor args, so we can compute every address up front and feed the
// precomputed peers into each constructor. The HOOK is the sole contract that additionally needs
// CREATE2 (its low 14 address bits must encode the permission flags = 0x25C3); it is salt-mined
// against the *precomputed* Vault address. See docs/deployment/DEPLOY_ORDER.md for the full
// rationale + the pure-CREATE2 alternative (needs a one-shot setter Contracts would have to add).
// ─────────────────────────────────────────────────────────────────────────────────────────────

import {Script, console2} from "forge-std/Script.sol";

import {GenesisVesting} from "../src/GenesisVesting.sol";
import {FeraToken} from "../src/FeraToken.sol";
import {FeraShare} from "../src/shares/FeraShare.sol";
import {AnchorStaking} from "../src/AnchorStaking.sol";
import {RevenueDistributor} from "../src/RevenueDistributor.sol";
import {EsFera} from "../src/EsFera.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {Distributor} from "../src/Distributor.sol";
import {FeraVault} from "../src/FeraVault.sol";
import {FeraHook} from "../src/FeraHook.sol";

import {IFeraToken} from "../src/interfaces/IFeraToken.sol";
import {IAnchorStaking} from "../src/interfaces/IAnchorStaking.sol";
import {IRevenueDistributor} from "../src/interfaces/IRevenueDistributor.sol";
import {IEsFera} from "../src/interfaces/IEsFera.sol";
import {IEmissionsController} from "../src/interfaces/IEmissionsController.sol";
import {IFeraHook} from "../src/interfaces/IFeraHook.sol";
import {FeraConstants} from "../src/libraries/FeraConstants.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title FERA Deploy
/// @notice Single-transaction-batch deploy of the FERA money-path contracts, resolving the three
///         constructor-arg cycles by nonce precompute (A/B/C above) + CREATE2 flag-mining for the
///         hook. Ownership/roles are set at construction to the Safe multisigs (no post-deploy
///         transferOwnership). The remaining config step (`addRewardToken`) is onlyRewardTokenAdmin
///         and therefore executed by the timelock Safe, NOT by this deployer EOA — the script
///         prints the exact calldata to enqueue. Stage-4 (contracts/VAULT_STRATEGY_V3.md §11):
///         `FeraVault.createBaseLimitPool` is now PERMISSIONLESS (no `onlyKeeper` gate) — anyone
///         may call it directly once the timelock Safe has curated `setAllowedQuoteAsset`/
///         `approveRwaFeed` for the relevant assets/feeds; it is no longer part of this script's
///         "must be executed by a role Safe" config batch.
contract Deploy is Script {
    // ── Hook flag mask (Uniswap v4 Hooks.sol low-14-bits) ──────────────────────────────────────
    uint160 internal constant HOOK_FLAG_MASK = 0x3FFF;
    uint160 internal constant HOOK_FLAG_TARGET = FeraConstants.HOOK_FLAG_TARGET; // 0x25C3 (D-14/V2-1)
    // Canonical deterministic CREATE2 factory (0x4e59…956C). MUST exist on-chain (CHAIN.md §8 D16);
    // if `cast code` is empty on 4663, deploy FERA's own minimal CREATE2 deployer and set this to its
    // address — the mined salt is only valid for THIS deployer address.
    // NOTE: `CREATE2_FACTORY` is INHERITED from forge-std `Base.sol` (same canonical address), so it is
    // NOT re-declared here (newer forge-std added it; a local copy now collides — build error).
    uint256 internal constant MINE_MAX_ITERS = 2_000_000; // ~1/16384 hit rate → millions of tries

    struct Config {
        // ── External immutables — ALL D-7-gated (CHAIN.md §2/§3). `cast code` + interface-probe
        //    each before a mainnet run; a wrong byte on poolManager bricks hook+vault. ───────────
        address poolManager; // TODO(chain-confirm) v4 PoolManager (CHAIN.md #11)
        // ── Governance / ops Safes (INFRA.md §Safe policy) ───────────────────────────────────────
        // "The team" — general team/admin address, NOT a DAO. Owns EmissionsController/Vault, is
        // rewardTokenAdmin (AnchorStaking), and the venue-allowlist/tier-config/RWA-feed-registry
        // approver in later stages. Stage-3: no longer wired as a Treasury.sol owner — Treasury.sol
        // is kept in the codebase (unused) for future optionality; see FERA_TREASURY_EOA below.
        address timelock; // FERA_TIMELOCK_SAFE — "the team" admin address (see above)
        address emissionsKeeper; // emissions keeper multisig (SEC-3 #3 / R-19)
        address rootPoster; // Merkle root-poster multisig (SEC-3 #3 / R-13 / R-19)
        address vaultKeeper; // Vault/RWA-strategy keeper (redundant across 2 providers, R-3)
        address opsSink; // RevenueDistributor 25% ops recipient
        // Stage-3 (contracts/VAULT_STRATEGY_V3.md §10 / OPEN_DECISIONS.md#OD-9): the treasury is a
        // PLAIN EOA (freely spendable, no timelock friction) — Treasury.sol is deliberately NOT
        // wired into this deploy anymore. This is the RevenueDistributor 25% recipient AND the
        // sole beneficiary of GenesisVesting (the genesis 10% is locked there, not sent here
        // directly unlocked).
        address treasuryEoa; // FERA_TREASURY_EOA
        // ── Revenue tokens to allowlist post-deploy (AnchorStaking.addRewardToken) ───────────────
        //    FERA is added implicitly below; list here the revenue ERC-20s (WETH, USDG, …).
        address weth; // TODO(chain-confirm) WETH on 4663 (CHAIN.md §8 B15)
        address usdg; // TODO(chain-confirm) USDG on 4663 (CHAIN.md §8 B14)
    }

    // Deployed addresses (populated by run()).
    GenesisVesting public genesisVesting;
    FeraToken public feraToken;
    FeraShare public shareImpl;
    AnchorStaking public anchor;
    RevenueDistributor public revDist;
    EsFera public esFera;
    EmissionsController public emissions;
    Distributor public distributor;
    FeraVault public vault;
    FeraHook public hook;

    function _loadConfig() internal view returns (Config memory c) {
        c.poolManager = vm.envAddress("FERA_POOL_MANAGER");
        c.timelock = vm.envAddress("FERA_TIMELOCK_SAFE");
        c.emissionsKeeper = vm.envAddress("FERA_EMISSIONS_KEEPER_SAFE");
        c.rootPoster = vm.envAddress("FERA_ROOT_POSTER_SAFE");
        c.vaultKeeper = vm.envAddress("FERA_VAULT_KEEPER");
        c.opsSink = vm.envAddress("FERA_OPS_SINK");
        c.treasuryEoa = vm.envAddress("FERA_TREASURY_EOA");
        c.weth = vm.envAddress("FERA_WETH");
        c.usdg = vm.envAddress("FERA_USDG");
    }

    function run() external {
        Config memory c = _loadConfig();
        uint256 pk = vm.envUint("FERA_DEPLOYER_PK");
        address D = vm.addr(pk);

        // A dedicated, single-purpose deployer whose *next* nonce is known. Any other tx from D
        // between precompute and broadcast invalidates the whole address map — use a fresh EOA.
        uint256 n = vm.getNonce(D);

        // ── 1) Precompute the full CREATE address map from D's nonce sequence ────────────────────
        //    Deploy order below MUST match these offsets exactly (asserted after each deploy).
        //    GenesisVesting has NO cyclic dependency — it only needs the (precomputed) FeraToken
        //    address and the beneficiary EOA, both already known here, so it slots into the exact
        //    n+0 offset Treasury.sol used to occupy without disturbing the n+1..n+9 offsets below
        //    or the Cycle B (EsFera/Distributor/EmissionsController) resolution.
        address aGenesisVesting = vm.computeCreateAddress(D, n + 0);
        address aFera = vm.computeCreateAddress(D, n + 1);
        address aShareImpl = vm.computeCreateAddress(D, n + 2);
        address aAnchor = vm.computeCreateAddress(D, n + 3);
        address aRevDist = vm.computeCreateAddress(D, n + 4);
        address aEsFera = vm.computeCreateAddress(D, n + 5);
        address aEmissions = vm.computeCreateAddress(D, n + 6);
        address aDistributor = vm.computeCreateAddress(D, n + 7);
        // n + 8 is the FeraToken.setEmissionsController() CALL (consumes a nonce, deploys nothing).
        address aVault = vm.computeCreateAddress(D, n + 9);
        // FeraHook is CREATE2 (flag-mined) — its address is independent of D's nonce.

        // ── 2) Mine the hook salt against the PRECOMPUTED vault address (Vault↔Hook cycle break) ──
        //    initCode = FeraHook.creationCode ++ abi.encode(poolManager, vaultAddr). The hook's
        //    constructor self-runs Hooks.validateHookPermissions(0x25C3) → a non-matching address
        //    reverts on deploy, so the mask predicate here must agree with getHookPermissions().
        bytes memory hookInit = abi.encodePacked(type(FeraHook).creationCode, abi.encode(c.poolManager, aVault));
        bytes32 hookInitHash = keccak256(hookInit);
        (bytes32 hookSalt, address aHook) = _mineHookSalt(hookInitHash);

        console2.log("deployer          ", D);
        console2.log("precompute:vault  ", aVault);
        console2.log("mined:hook        ", aHook);
        console2.log("mined:salt(uint)  ", uint256(hookSalt));

        // ── 3) Broadcast the deploy in the precomputed order ─────────────────────────────────────
        vm.startBroadcast(pk);

        // Stage-3: GenesisVesting is deployed FIRST, referencing the PRECOMPUTED FeraToken address
        // (its constructor only STORES the token reference — no external call at construction time,
        // so it is safe to point at a not-yet-deployed address, exactly like the AnchorStaking ↔
        // RevenueDistributor precompute below). The 1yr-cliff/3yr-linear schedule starts NOW.
        genesisVesting = new GenesisVesting(IERC20(aFera), c.treasuryEoa); // n+0
        _eq(address(genesisVesting), aGenesisVesting, "genesisVesting");

        feraToken = new FeraToken(address(genesisVesting)); // n+1 — 10% genesis mint to GenesisVesting; D == _deployer
        _eq(address(feraToken), aFera, "feraToken");

        shareImpl = new FeraShare(); // n+2 — inert clone template (vault==0)
        _eq(address(shareImpl), aShareImpl, "shareImpl");

        // Cycle A: AnchorStaking(fera, revDist*, rewardTokenAdmin=timelock) ↔ RevenueDistributor(anchor*, treasuryEoa, ops)
        anchor = new AnchorStaking(IERC20(address(feraToken)), IRevenueDistributor(aRevDist), c.timelock); // n+3
        _eq(address(anchor), aAnchor, "anchor");
        // Stage-3: the 25% treasury leg is now the PLAIN EOA (FERA_TREASURY_EOA), never Treasury.sol.
        revDist = new RevenueDistributor(aAnchor, c.treasuryEoa, c.opsSink); // n+4
        _eq(address(revDist), aRevDist, "revDist");

        // Cycle B (DEPLOY-1): EsFera(minter=Distributor*) → Distributor(esFera*, controller=Emissions*) → EmissionsController(esFera*)
        esFera = new EsFera(
            IFeraToken(address(feraToken)), IAnchorStaking(aAnchor), IRevenueDistributor(aRevDist), aDistributor
        ); // n+5 — minter is the Distributor (mints esFERA on claim)
        _eq(address(esFera), aEsFera, "esFera");
        emissions = new EmissionsController(IFeraToken(address(feraToken)), aEsFera, c.emissionsKeeper, c.timelock); // n+6
        _eq(address(emissions), aEmissions, "emissions");
        distributor = new Distributor(IEsFera(aEsFera), c.rootPoster, IEmissionsController(aEmissions)); // n+7
        _eq(address(distributor), aDistributor, "distributor");

        // One-shot FERA↔EmissionsController wiring (deployer-only setter; breaks that cycle already).
        feraToken.setEmissionsController(address(emissions)); // n+8 (CALL)

        // Cycle C: FeraVault(pm, hook=mined, revDist, anchorStaking, shareImpl, keeper, timelock)
        // v3.1 unified fee-routing (contracts/VAULT_STRATEGY_V3.md §9): wire the REAL AnchorStaking
        // (already deployed at n+3) so the Vault can introspect the reward-token allowlist +
        // totalStaked() at fee-collection time.
        vault = new FeraVault(
            IPoolManager(c.poolManager),
            IFeraHook(aHook),
            IRevenueDistributor(address(revDist)),
            IAnchorStaking(address(anchor)),
            address(shareImpl),
            c.vaultKeeper,
            c.timelock
        ); // n+9
        _eq(address(vault), aVault, "vault");

        // Hook via CREATE2 (routed through CREATE2_FACTORY). Constructor validates the 0x25C3 flags.
        hook = new FeraHook{salt: hookSalt}(IPoolManager(c.poolManager), address(vault));
        _eq(address(hook), aHook, "hook");

        vm.stopBroadcast();

        // ── 4) Assert the hook address is spec-legal (belt-and-suspenders; ctor already checked) ──
        require(uint160(address(hook)) & HOOK_FLAG_MASK == HOOK_FLAG_TARGET, "hook: flag mask");
        require(uint8(uint160(address(hook)) >> 152) != 0x91, "hook: 0x91 prefix (D-8)");
        require(address(hook) == address(vault.hook()), "hook<->vault wiring");

        _printPostDeploy(c);
    }

    // ── CREATE2 salt miner: `& 0x3FFF == 0x25C3` AND first byte != 0x91 (D-8) ───────────────────
    function _mineHookSalt(bytes32 initHash) internal pure returns (bytes32 salt, address addr) {
        for (uint256 i = 0; i < MINE_MAX_ITERS; ++i) {
            salt = bytes32(i);
            addr = vm.computeCreate2Address(salt, initHash, CREATE2_FACTORY);
            if (uint160(addr) & HOOK_FLAG_MASK == HOOK_FLAG_TARGET && uint8(uint160(addr) >> 152) != 0x91) {
                return (salt, addr);
            }
        }
        revert("mine: no salt in MINE_MAX_ITERS (raise cap)");
    }

    function _eq(address got, address want, string memory who) internal pure {
        require(got == want, string.concat("precompute mismatch: ", who));
    }

    /// @dev Prints the role-gated config batches the SAFES must execute after this deploy.
    ///      addRewardToken + setForfeitNotifier are onlyRewardTokenAdmin (timelock); `setAllowedQuoteAsset`
    ///      / `approveRwaFeed` / `setEmissionsEligible` are onlyOwner (timelock). `createBaseLimitPool`
    ///      itself is PERMISSIONLESS (contracts/VAULT_STRATEGY_V3.md §11) — no role Safe needs to call it.
    function _printPostDeploy(Config memory c) internal view {
        console2.log("== GenesisVesting: 100,000,000 FERA locked (1yr cliff / 3yr linear / 4yr total) ==");
        console2.log("  genesisVesting ->", address(genesisVesting), " beneficiary ->", c.treasuryEoa);
        console2.log("== TIMELOCK SAFE must enqueue AnchorStaking.addRewardToken for each revenue token ==");
        console2.log("  addRewardToken(FERA) ->", address(feraToken));
        console2.log("  addRewardToken(WETH) ->", c.weth);
        console2.log("  addRewardToken(USDG) ->", c.usdg);
        // REC-8 deploy dependency: EsFera's instant-exit forfeit stakers-third is booked into the FERA
        // reward accumulator via AnchorStaking.notifyForfeitShare, which is gated to this notifier. FERA
        // MUST also be addRewardToken'd (above) for stakers to accrue it — else the third is HELD (never
        // lost) until FERA is allowlisted and stakers exist.
        console2.log("== TIMELOCK SAFE must call AnchorStaking.setForfeitNotifier(esFera) (REC-8, one-time) ==");
        console2.log("  setForfeitNotifier ->", address(esFera));
        console2.log("== v3.3: pool creation is now PERMISSIONLESS (contracts/VAULT_STRATEGY_V3.md sec11) ==");
        console2.log("  anyone may call vault.createBaseLimitPool(...) directly; vaultKeeper is NOT required");
        console2.log("== TIMELOCK SAFE (\"the team\") must curate BEFORE any pool can be created against a given pair ==");
        console2.log("  vault.setAllowedQuoteAsset(WETH, true) ->", c.weth);
        console2.log("  vault.setAllowedQuoteAsset(USDG, true) ->", c.usdg);
        console2.log("  vault.approveRwaFeed(feed, description) -- once per verified Chainlink feed, RWA pools only");
        console2.log("  vault.setEmissionsEligible(poolId, true) -- per pool, opt-in only, esFERA attribution ONLY");
        console2.log("== v3.5: the AUTOMATED KEEPER acts on NO pool until explicitly activated (Finding-1 hardening) ==");
        console2.log("  vault.setKeeperActive(poolId, true) -- per pool, ONLY after reviewing its native token");
        console2.log("  (a hostile transfer hook could reenter PoolManager during rebalance settlement --");
        console2.log("   review bytecode/behavior before activating a permissionlessly-created pool's native token)");
        console2.log("  For >1 pool at once: vault.setKeeperActiveBatch(poolIds, true) -- one tx, same checks apply");
        console2.log("  BEFORE re-enabling keeper.yml's cron: vault.inactiveKeeperPools(allLivePoolIds) MUST return");
        console2.log("   empty for every pool you intend to run the keeper on -- a forgotten pool here is silent");
        console2.log("   (see FeraVault.sol keeperActive NatSpec / audit finding: silent un-activated pools)");
        console2.log("  vault:", address(vault), " hook:", address(hook));
    }
}

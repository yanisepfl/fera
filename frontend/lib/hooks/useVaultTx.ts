"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  useAccount,
  useConfig,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import { simulateContract, waitForTransactionReceipt } from "wagmi/actions";
import { useQueryClient } from "@tanstack/react-query";
import { BaseError, erc20Abi } from "viem";
import { activeChain } from "@/config/chains";
import { VAULT, poolTokenPair, type LivePool } from "@/config/pools";
import { feraVaultAbi } from "@/lib/abi/feraVault";

/**
 * REAL vault transactions on Robinhood Chain (4663) for pools in config/pools.ts.
 *
 * Both hooks follow the same shape: chain reads (balances / allowances / NAV / holds)
 * via wagmi `useReadContracts`, writes via `useWriteContract`, and the in-flight vault
 * tx tracked with `useWaitForTransactionReceipt` so the dialogs can show honest
 * pending → confirmed → failed states. Every call pins `chainId` to the active chain,
 * so wagmi switches the wallet to 4663 (or surfaces the refusal) before signing.
 *
 * Token amounts are in the POOL'S token0/token1 order (config/pools.ts#poolTokenPair —
 * `quoteIsToken0` decides which side the quote is). The dialogs work in memecoin/quote
 * terms and map through `poolTokenPair`, never by guessing sort order.
 */

const CHAIN_ID = activeChain.id;

/**
 * Slippage tolerance between the pre-send on-chain quote and inclusion, in bps.
 * Both vault calls are SIMULATED with min=0 right before signing — the contract's own
 * math prices the outcome at the current state — then sent with
 * `min = quoted × (1 − tolerance)`. 1% absorbs a memecoin moving between quote and
 * inclusion; a bigger move reverts with `Slippage` ("try again"), never a silent
 * short-change. The simulation also surfaces reverts (TWAP gate, cooldown, paused)
 * BEFORE any gas is spent.
 */
const SLIPPAGE_TOLERANCE_BPS = 100n;

const withTolerance = (quoted: bigint): bigint =>
  quoted - (quoted * SLIPPAGE_TOLERANCE_BPS) / 10_000n;

/** UI-facing lifecycle of a (multi-step) vault transaction. */
export type VaultTxPhase =
  | { step: "idle" }
  | { step: "approve"; symbol: string } // wallet prompt for an ERC-20 approve
  | { step: "approving"; symbol: string; hash: `0x${string}` } // approve tx in flight
  | { step: "wallet" } // wallet prompt for the vault call itself
  | { step: "tx"; hash: `0x${string}` } // vault tx broadcast, awaiting receipt
  | { step: "success"; hash: `0x${string}` }
  | { step: "error"; message: string };

export const txBusy = (p: VaultTxPhase) =>
  p.step !== "idle" && p.step !== "success" && p.step !== "error";

/** Map wallet/RPC/contract errors to honest, human copy (known vault errors by name). */
export function txErrorMessage(e: unknown): string {
  const raw =
    e instanceof BaseError
      ? e.shortMessage || e.message
      : e instanceof Error
        ? e.message
        : String(e);
  // Sniff custom-error NAMES across the full detail chain (shortMessage often elides them).
  const all =
    e instanceof BaseError
      ? [e.message, ...(e.metaMessages ?? [])].join(" ")
      : raw;
  if (/user (rejected|denied)|rejected the request/i.test(all))
    return "You cancelled the transaction in your wallet.";
  if (/CooldownActive/.test(all))
    return "These shares are still inside the one-time 1-hour post-deposit hold. Try again once it lapses.";
  if (/TwapGateExceeded/.test(all))
    return "Deposits are paused for a moment — the price is moving fast right now. This is a safety pause that protects the price you enter at; it reopens on its own, usually within a minute.";
  if (/DepositsPaused/.test(all)) return "Deposits for this pool are paused right now.";
  if (/ZeroDeposit/.test(all)) return "Enter an amount on at least one side.";
  if (/Slippage/.test(all))
    return "The share quote moved while the transaction was in flight. Try again.";
  if (/UnknownPool|UnknownTranche/.test(all))
    return "This pool or risk profile isn't initialized on-chain.";
  if (/insufficient funds/i.test(all))
    return "Not enough ETH to cover gas on Robinhood Chain.";
  if (/InsufficientBalance|exceeds balance/i.test(all))
    return "Balance too low for that amount.";
  return raw.length > 200 ? `${raw.slice(0, 200)}…` : raw;
}

/** allowFailure-tolerant result picker for useReadContracts data. */
function pick<T>(
  data: readonly { status: string; result?: unknown }[] | undefined,
  i: number,
): T | undefined {
  const r = data?.[i];
  return r && r.status === "success" ? (r.result as T) : undefined;
}

/** Shared receipt→phase machinery for the final vault tx. */
function useVaultReceipt(
  vaultHash: `0x${string}` | undefined,
  setPhase: (p: VaultTxPhase) => void,
  onSettled: () => void,
) {
  const queryClient = useQueryClient();
  const receipt = useWaitForTransactionReceipt({
    hash: vaultHash,
    chainId: CHAIN_ID,
    query: { enabled: !!vaultHash },
  });
  useEffect(() => {
    if (!vaultHash) return;
    if (receipt.data) {
      if (receipt.data.status === "success") {
        setPhase({ step: "success", hash: vaultHash });
        // Balances, allowances, NAV and share balances all just changed on-chain.
        queryClient.invalidateQueries({ queryKey: ["readContract"] });
        queryClient.invalidateQueries({ queryKey: ["readContracts"] });
        queryClient.invalidateQueries({ queryKey: ["positions"] });
      } else {
        setPhase({ step: "error", message: "The transaction reverted on-chain." });
      }
      onSettled();
    } else if (receipt.error) {
      setPhase({ step: "error", message: txErrorMessage(receipt.error) });
      onSettled();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [receipt.data, receipt.error, vaultHash]);
}

// ---------------------------------------------------------------------------
// Deposit
// ---------------------------------------------------------------------------

export function useVaultDeposit(live: LivePool | undefined) {
  const { address } = useAccount();
  const config = useConfig();
  const { writeContractAsync } = useWriteContract();
  const [phase, setPhase] = useState<VaultTxPhase>({ step: "idle" });
  const [vaultHash, setVaultHash] = useState<`0x${string}` | undefined>();

  const pair = useMemo(() => (live ? poolTokenPair(live) : undefined), [live]);

  const reads = useReadContracts({
    allowFailure: true,
    contracts:
      live && pair && address
        ? [
            { address: pair.token0.address, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: CHAIN_ID },
            { address: pair.token1.address, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: CHAIN_ID },
            { address: pair.token0.address, abi: erc20Abi, functionName: "allowance", args: [address, VAULT], chainId: CHAIN_ID },
            { address: pair.token1.address, abi: erc20Abi, functionName: "allowance", args: [address, VAULT], chainId: CHAIN_ID },
            { address: VAULT, abi: feraVaultAbi, functionName: "depositsPaused", args: [live.poolId], chainId: CHAIN_ID },
          ]
        : [],
    query: { enabled: !!(live && address), refetchInterval: 12_000 },
  });

  const balance0 = pick<bigint>(reads.data, 0);
  const balance1 = pick<bigint>(reads.data, 1);
  const allowance0 = pick<bigint>(reads.data, 2);
  const allowance1 = pick<bigint>(reads.data, 3);
  const depositsPaused = pick<boolean>(reads.data, 4);

  useVaultReceipt(vaultHash, setPhase, reads.refetch);

  /** amounts are in POOL token0/token1 order (see poolTokenPair). */
  const submit = useCallback(
    async (args: { amount0: bigint; amount1: bigint; tranche: number; minShares?: bigint }) => {
      if (!live || !pair) return;
      try {
        setVaultHash(undefined);
        // ERC-20 approvals for each nonzero side whose allowance is short. EXACT-amount
        // approvals on purpose: the vault is never left holding a standing allowance.
        const sides = [
          { token: pair.token0, amount: args.amount0, allowance: allowance0 },
          { token: pair.token1, amount: args.amount1, allowance: allowance1 },
        ];
        for (const s of sides) {
          if (s.amount === 0n) continue;
          if (s.allowance !== undefined && s.allowance >= s.amount) continue;
          setPhase({ step: "approve", symbol: s.token.symbol });
          const hash = await writeContractAsync({
            address: s.token.address,
            abi: erc20Abi,
            functionName: "approve",
            args: [VAULT, s.amount],
            chainId: CHAIN_ID,
          });
          setPhase({ step: "approving", symbol: s.token.symbol, hash });
          const r = await waitForTransactionReceipt(config, { hash, chainId: CHAIN_ID });
          if (r.status !== "success") throw new Error(`The ${s.token.symbol} approval reverted.`);
        }

        setPhase({ step: "wallet" });
        // Slippage floor: simulate the deposit (allowances are in place now) to get the
        // contract's own sharesMinted quote at the current state, then send with
        // minShares = quoted × (1 − SLIPPAGE_TOLERANCE_BPS). See the constant's docs.
        let minShares = args.minShares;
        if (minShares === undefined) {
          const sim = await simulateContract(config, {
            address: VAULT,
            abi: feraVaultAbi,
            functionName: "deposit",
            args: [live.poolId, args.tranche, args.amount0, args.amount1, 0n],
            chainId: CHAIN_ID,
            account: address,
          });
          minShares = withTolerance(sim.result);
        }
        const hash = await writeContractAsync({
          address: VAULT,
          abi: feraVaultAbi,
          functionName: "deposit",
          args: [live.poolId, args.tranche, args.amount0, args.amount1, minShares],
          chainId: CHAIN_ID,
        });
        setVaultHash(hash);
        setPhase({ step: "tx", hash });
      } catch (e) {
        setPhase({ step: "error", message: txErrorMessage(e) });
      }
    },
    [live, pair, allowance0, allowance1, config, writeContractAsync, address],
  );

  const reset = useCallback(() => {
    setPhase({ step: "idle" });
    setVaultHash(undefined);
  }, []);

  return {
    pair,
    balance0,
    balance1,
    allowance0,
    allowance1,
    depositsPaused,
    phase,
    submit,
    reset,
  };
}

// ---------------------------------------------------------------------------
// Share-address resolution (any tranche, any registry pool)
// ---------------------------------------------------------------------------

/**
 * Resolve a tranche's FeraShare ERC-20 address for a registry pool.
 *
 * Tranche 0 is always `live.share` (config/pools.ts — confirmed for every live pool,
 * no chain read needed). Every OTHER tranche's clone address is deliberately not
 * hardcoded per pool (only one has been confirmed by hand so far) — it's resolved
 * live via the vault's general `FeraVault.shareToken(poolId, tranche)` getter, which
 * works for any pool since `createBaseLimitPool` initializes every tranche's clone at
 * pool creation. The read is cheap (one `eth_call`, cached indefinitely — a tranche's
 * share address never changes once set) and always correct, so it's preferred over
 * maintaining a second hardcoded address per pool in the registry.
 */
function useShareAddress(
  live: LivePool | undefined,
  tranche: number,
): { address: `0x${string}` | undefined; isLoading: boolean } {
  const needsRead = !!live && tranche !== 0;
  const read = useReadContract({
    address: VAULT,
    abi: feraVaultAbi,
    functionName: "shareToken",
    args: live ? [live.poolId, tranche] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: needsRead, staleTime: Infinity },
  });
  if (!live) return { address: undefined, isLoading: false };
  if (tranche === 0) return { address: live.share, isLoading: false };
  return { address: read.data, isLoading: read.isLoading };
}

// ---------------------------------------------------------------------------
// Withdraw (proportional, in-kind — FeraVault.withdraw)
// ---------------------------------------------------------------------------

/**
 * `tranche` selects which risk class's shares this withdraws (0 = Core/"Active",
 * 1 = Anchor/"Steady" — lib/riskClass.ts#RISK_CLASS_META has the canonical mapping).
 * The tranche's share address is resolved via `useShareAddress` above, so every
 * registry pool works for both tranches without a second hardcoded address each.
 */
export function useVaultWithdraw(live: LivePool | undefined, tranche = 0) {
  const { address } = useAccount();
  const config = useConfig();
  const { writeContractAsync } = useWriteContract();
  const [phase, setPhase] = useState<VaultTxPhase>({ step: "idle" });
  const [vaultHash, setVaultHash] = useState<`0x${string}` | undefined>();

  const { address: shareAddress, isLoading: shareAddressLoading } = useShareAddress(live, tranche);
  const ready = !!(live && address && shareAddress);

  const reads = useReadContracts({
    allowFailure: true,
    contracts:
      ready
        ? [
            { address: shareAddress, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: CHAIN_ID },
            { address: shareAddress, abi: erc20Abi, functionName: "totalSupply", chainId: CHAIN_ID },
            { address: VAULT, abi: feraVaultAbi, functionName: "quoteNav", args: [live!.poolId, tranche], chainId: CHAIN_ID },
            // real on-chain hold: lastDepositTs + 1h gates withdraw (CooldownActive)
            { address: VAULT, abi: feraVaultAbi, functionName: "lastDepositTs", args: [live!.poolId, BigInt(tranche), address!], chainId: CHAIN_ID },
          ]
        : [],
    query: { enabled: ready, refetchInterval: 12_000 },
  });

  const shareBalance = pick<bigint>(reads.data, 0);
  const shareSupply = pick<bigint>(reads.data, 1);
  const navQuoteWei = pick<bigint>(reads.data, 2);
  const lastDepositTs = pick<bigint>(reads.data, 3);

  useVaultReceipt(vaultHash, setPhase, reads.refetch);

  const submit = useCallback(
    async (shares: bigint) => {
      if (!live) return;
      try {
        setVaultHash(undefined);
        setPhase({ step: "wallet" });
        // Slippage floor: a proportional in-kind withdraw prices nothing, but v4 burn
        // amounts can drift a hair between quote and inclusion (swaps landing in the
        // same block). Simulate to get the contract's own (amount0, amount1) quote,
        // then send with mins = quoted × (1 − SLIPPAGE_TOLERANCE_BPS).
        const sim = await simulateContract(config, {
          address: VAULT,
          abi: feraVaultAbi,
          functionName: "withdraw",
          args: [live.poolId, tranche, shares, 0n, 0n],
          chainId: CHAIN_ID,
          account: address,
        });
        const [quoted0, quoted1] = sim.result as readonly [bigint, bigint];
        const hash = await writeContractAsync({
          address: VAULT,
          abi: feraVaultAbi,
          functionName: "withdraw",
          args: [live.poolId, tranche, shares, withTolerance(quoted0), withTolerance(quoted1)],
          chainId: CHAIN_ID,
        });
        setVaultHash(hash);
        setPhase({ step: "tx", hash });
      } catch (e) {
        setPhase({ step: "error", message: txErrorMessage(e) });
      }
    },
    [live, tranche, writeContractAsync, config, address],
  );

  const reset = useCallback(() => {
    setPhase({ step: "idle" });
    setVaultHash(undefined);
  }, []);

  return {
    shareBalance,
    shareSupply,
    navQuoteWei,
    /** unix seconds of the connected account's last deposit (0n = never). */
    lastDepositTs,
    /** the tranche's resolved FeraShare address (undefined while tranche 1's is resolving). */
    shareAddress,
    /** true while the share address and/or first chain read round-trip is in flight. */
    readsPending: shareAddressLoading || reads.isLoading,
    phase,
    submit,
    reset,
  };
}

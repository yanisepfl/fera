"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  useAccount,
  useConfig,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
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
    return "Deposits are briefly gated - the pool price has moved too far from its short-window average. Try again in a minute.";
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
        // TODO(slippage): minShares defaults to 0 for now. Before real size flows through,
        // quote expected shares off quoteNav()/share totalSupply() at submit time and pass
        // minShares = expected × (1 − tolerance) so NAV moves between quote and inclusion
        // can't short-change the mint (the contract enforces sharesMinted ≥ minShares > 0).
        const hash = await writeContractAsync({
          address: VAULT,
          abi: feraVaultAbi,
          functionName: "deposit",
          args: [live.poolId, args.tranche, args.amount0, args.amount1, args.minShares ?? 0n],
          chainId: CHAIN_ID,
        });
        setVaultHash(hash);
        setPhase({ step: "tx", hash });
      } catch (e) {
        setPhase({ step: "error", message: txErrorMessage(e) });
      }
    },
    [live, pair, allowance0, allowance1, config, writeContractAsync],
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
// Withdraw (proportional, in-kind — FeraVault.withdraw)
// ---------------------------------------------------------------------------

/**
 * NOTE: wired for tranche 0 ("Steady"/Core is tranche 0 on-chain) — config/pools.ts only
 * carries the tranche-0 FeraShare clone addresses (only tranche 0 is seeded). When Anchor
 * (tranche 1) shares go live, add their share addresses to the registry and pass tranche 1.
 */
export function useVaultWithdraw(live: LivePool | undefined, tranche = 0) {
  const { address } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const [phase, setPhase] = useState<VaultTxPhase>({ step: "idle" });
  const [vaultHash, setVaultHash] = useState<`0x${string}` | undefined>();

  const reads = useReadContracts({
    allowFailure: true,
    contracts:
      live && address
        ? [
            { address: live.share, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: CHAIN_ID },
            { address: live.share, abi: erc20Abi, functionName: "totalSupply", chainId: CHAIN_ID },
            { address: VAULT, abi: feraVaultAbi, functionName: "quoteNav", args: [live.poolId, tranche], chainId: CHAIN_ID },
            // real on-chain hold: lastDepositTs + 1h gates withdraw (CooldownActive)
            { address: VAULT, abi: feraVaultAbi, functionName: "lastDepositTs", args: [live.poolId, BigInt(tranche), address], chainId: CHAIN_ID },
          ]
        : [],
    query: { enabled: !!(live && address), refetchInterval: 12_000 },
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
        // TODO(slippage): minAmount0/minAmount1 are 0 for now. A proportional in-kind
        // withdraw prices nothing, but v4 burn amounts can still drift a hair between
        // quote and inclusion — before real size, preview the pro-rata amounts and pass
        // mins with a small tolerance.
        const hash = await writeContractAsync({
          address: VAULT,
          abi: feraVaultAbi,
          functionName: "withdraw",
          args: [live.poolId, tranche, shares, 0n, 0n],
          chainId: CHAIN_ID,
        });
        setVaultHash(hash);
        setPhase({ step: "tx", hash });
      } catch (e) {
        setPhase({ step: "error", message: txErrorMessage(e) });
      }
    },
    [live, tranche, writeContractAsync],
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
    /** true while the first chain read round-trip is still in flight. */
    readsPending: reads.isLoading,
    phase,
    submit,
    reset,
  };
}

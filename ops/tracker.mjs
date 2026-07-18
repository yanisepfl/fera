#!/usr/bin/env node
/**
 * FERA pool digest → Telegram. Zero dependencies (Node 20+, built-in fetch).
 *
 * Reports, per live pool over the lookback window: swap count, volume (USD, valued on
 * the wWETH leg), the biggest trade (with tx link), how many swaps came through the
 * official UniversalRouter (= routed user flow, the metric that proves routing), and
 * the live dynamic fee + vault NAV right now.
 *
 * Runs anywhere:
 *   node ops/tracker.mjs                     # dry run — prints the digest to stdout
 *   TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... node ops/tracker.mjs   # sends to TG
 *
 * Env (all optional): RPC_URL, LOOKBACK_HOURS (default 24).
 * Scheduled for free by .github/workflows/pool-digest.yml (daily + manual trigger).
 *
 * NOTE: the pool registry below mirrors frontend/config/pools.ts — keep in sync when
 * pools are added (single source there; duplicated here so this file stays dep-free).
 */

const RPC = process.env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com";
const HOURS = Number(process.env.LOOKBACK_HOURS ?? 24);
const PM = "0x8366a39cc670b4001a1121b8f6a443a643e40951"; // v4 PoolManager
const VAULT = "0xa8cF82797ecBC8C5cD5F83D60e189dbDc88D959a";
const HOOK = "0x96CE193F25db9b75743332bB7C94e545f1a225C3";
const ROUTER = "0x8876789976decbfcbbbe364623c63652db8c0904"; // UniversalRouter (official)
const WWETH = "0x0bd7d308f8e1639fab988df18a8011f41eacad73";
const EXPLORER = "https://robinhoodchain.blockscout.com";
const EARLIEST = 12455000; // first FERA pool creation block

// keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
const SWAP_TOPIC =
  "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f";

// symbol, poolId, quoteIsToken0 (true = wWETH is token0)
const POOLS = [
  ["TENDIES", "0x781f4bd64678be81a559f58bb124c570fb86abc04831f1c41212984340df9a12", true],
  ["VIRTUAL", "0x4412b3443d6f50184af006e8e0fa2573ef0b7ef7ddb675738971311a27236ef7", true],
  ["GME", "0x848c3b7e44feed741b097eecba7846dd96414e8b1fc21488c71c8b9bcb115cb5", true],
  ["WALLET", "0x877c04e865fffdfb450a86e5d1c3e5892ea56d5e33e3d56733249330a5b234b3", false],
  ["PONS", "0x4f382e3ceda365063d6824280583f2c485fe4f5c21178c39901c45f11a47e44d", true],
];

let rpcId = 0;
async function rpc(method, params) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
  });
  const j = await res.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

/** int128 from a 32-byte hex slot (two's complement). */
function int128(slot) {
  let v = BigInt("0x" + slot);
  if (v >= 1n << 255n) v -= 1n << 256n; // int256-encoded
  return v;
}
const hexInt = (h) => Number(BigInt(h));

async function main() {
  // Block window: sample the chain's block rate, then walk back LOOKBACK_HOURS.
  const latest = await rpc("eth_getBlockByNumber", ["latest", false]);
  const latestNum = hexInt(latest.number);
  const latestTs = hexInt(latest.timestamp);
  const SAMPLE = 50_000;
  const past = await rpc("eth_getBlockByNumber", [
    "0x" + Math.max(latestNum - SAMPLE, EARLIEST).toString(16),
    false,
  ]);
  const rate = (latestNum - hexInt(past.number)) / Math.max(latestTs - hexInt(past.timestamp), 1);
  const fromBlock = Math.max(Math.floor(latestNum - HOURS * 3600 * rate), EARLIEST);

  // One log query covers all pools (topic1 = OR-list of poolIds).
  const logs = await rpc("eth_getLogs", [
    {
      address: PM,
      fromBlock: "0x" + fromBlock.toString(16),
      toBlock: "latest",
      topics: [SWAP_TOPIC, POOLS.map(([, id]) => id)],
    },
  ]);

  // wWETH price for USD valuation (best-effort; falls back to wWETH units).
  let ethUsd = 0;
  try {
    const gt = await (
      await fetch(
        `https://api.geckoterminal.com/api/v2/networks/robinhood/tokens/${WWETH}`,
        { headers: { accept: "application/json" } },
      )
    ).json();
    ethUsd = Number(gt?.data?.attributes?.price_usd ?? 0);
  } catch {
    /* keep 0 → report in wWETH */
  }

  const usd = (weth) => (ethUsd ? `$${(weth * ethUsd).toFixed(2)}` : `${weth.toFixed(5)} wWETH`);

  // Aggregate per pool.
  const stats = new Map(POOLS.map(([sym, id, q0]) => [id.toLowerCase(), {
    sym, q0, swaps: 0, vol: 0, router: 0, senders: new Set(), big: null,
  }]));
  for (const l of logs) {
    const s = stats.get(l.topics[1].toLowerCase());
    if (!s) continue;
    const d = l.data.slice(2);
    const a0 = int128(d.slice(0, 64));
    const a1 = int128(d.slice(64, 128));
    const wethLeg = s.q0 ? a0 : a1;
    const weth = Math.abs(Number(wethLeg)) / 1e18;
    const sender = ("0x" + l.topics[2].slice(-40)).toLowerCase();
    s.swaps++;
    s.vol += weth;
    s.senders.add(sender);
    if (sender === ROUTER) s.router++;
    if (!s.big || weth > s.big.weth) s.big = { weth, tx: l.transactionHash };
  }

  // Live fee + NAV per pool (eth_call).
  async function call(to, data) {
    return rpc("eth_call", [{ to, data }, "latest"]);
  }
  const feeSel = "0x04cfce0a"; // cast sig "getDynamicFee(bytes32)"
  const navSel = "0x1e5f9404"; // cast sig "quoteNav(bytes32,uint8)"
  for (const [, id] of POOLS) {
    const s = stats.get(id.toLowerCase());
    try {
      s.fee = Number(BigInt(await call(HOOK, feeSel + id.slice(2)))) / 10_000;
      s.nav =
        Number(BigInt(await call(VAULT, navSel + id.slice(2) + "0".repeat(64)))) / 1e18;
    } catch {
      /* leave undefined → render "—" */
    }
  }

  // Compose the digest.
  const rows = [...stats.values()].sort((a, b) => b.vol - a.vol);
  const totVol = rows.reduce((x, r) => x + r.vol, 0);
  const totSwaps = rows.reduce((x, r) => x + r.swaps, 0);
  const totRouter = rows.reduce((x, r) => x + r.router, 0);
  const lines = [
    `<b>FERA pools — last ${HOURS}h</b>`,
    `${totSwaps} swaps · ${usd(totVol)} volume · <b>${totRouter} via Uniswap router</b>`,
    "",
  ];
  for (const r of rows) {
    const fee = r.fee !== undefined ? `${r.fee.toFixed(2)}%` : "—";
    const nav = r.nav !== undefined ? usd(r.nav) : "—";
    lines.push(
      `<b>${r.sym}</b>  ${r.swaps} swaps · ${usd(r.vol)} vol · ${r.router} routed · ` +
        `fee ${fee} · NAV ${nav}`,
    );
    if (r.big)
      lines.push(
        `   biggest: ${usd(r.big.weth)} — <a href="${EXPLORER}/tx/${r.big.tx}">tx</a>`,
      );
  }
  lines.push("", `<a href="${EXPLORER}/address/${VAULT}">vault</a> · block ${latestNum}`);
  const text = lines.join("\n");

  const token = process.env.TELEGRAM_BOT_TOKEN;
  const chat = process.env.TELEGRAM_CHAT_ID;
  if (token && chat) {
    const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        chat_id: chat,
        text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
      }),
    });
    const j = await res.json();
    if (!j.ok) throw new Error(`telegram: ${j.description}`);
    console.log("digest sent to Telegram");
  } else {
    console.log("(dry run — set TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID to send)\n");
    console.log(text.replace(/<[^>]+>/g, ""));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

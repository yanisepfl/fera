#!/usr/bin/env node
/**
 * FERA pool digest → Telegram. Zero dependencies (Node 20+, built-in fetch).
 *
 * Per pool over the lookback window: swaps, volume (valued via the pool's own spot
 * price — no external price feed needed beyond wWETH/USD), routed-through-the-official-
 * UniversalRouter count (the routing-proof metric), distinct traders, the day's traded
 * fee range, LP fees actually collected, user deposits/withdrawals, keeper strategy
 * actions (by name), live fee + NAV, and whether every band is in range right now.
 *
 * Layout is tuned for a phone: short lines, one compact card per pool.
 *
 *   node ops/tracker.mjs                      # dry run — prints to stdout
 *   TELEGRAM_BOT_TOKEN=.. TELEGRAM_CHAT_ID=.. node ops/tracker.mjs
 *
 * Env (optional): RPC_URL, LOOKBACK_HOURS (default 24).
 * Scheduled free by .github/workflows/pool-digest.yml.
 *
 * NOTE: the registry below mirrors frontend/config/pools.ts — keep in sync.
 */

const RPC = process.env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com";
const HOURS = Number(process.env.LOOKBACK_HOURS ?? 24);
const PM = "0x8366a39cc670b4001a1121b8f6a443a643e40951"; // v4 PoolManager
const VAULT = "0xa8cF82797ecBC8C5cD5F83D60e189dbDc88D959a";
const HOOK = "0x96CE193F25db9b75743332bB7C94e545f1a225C3";
const STATE_VIEW = "0xf3334192d15450cdd385c8b70e03f9a6bd9e673b";
const ROUTER = "0x8876789976decbfcbbbe364623c63652db8c0904"; // official UniversalRouter
const WWETH = "0x0bd7d308f8e1639fab988df18a8011f41eacad73";
const EXPLORER = "https://robinhoodchain.blockscout.com";
const EARLIEST = 12455000; // first FERA pool creation block

// event topics (verified with `cast keccak`)
const T_SWAP = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f";
const T_ML = "0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec";
const T_DEPOSIT = "0x470df6437ccfe1ef0651c4b095076019cb0fb9daf3c2311bd2d439df1dd22ba4";
const T_WITHDRAW = "0x6de3a2d24ac72cba8b5ac58ddcae2621adf76b25c5fffa56c68162f2547f9698";
const T_FEES = "0xaf872d036f3712203ffc5798fc6a59a67b9ed556c9b201ce33aef187b77c238e";
const T_STRAT = "0x6940430bac5daa9f96cbe8a72f54dac3f41f47d42a5c75056e2b66e87d77132f";

// FeraTypes.StrategyKind — human names
const KIND = {
  0: "init", 1: "recenter", 2: "widen", 3: "partial-withdraw", 4: "compound",
  5: "drip", 6: "consolidate", 7: "limit deploy", 8: "base recenter",
  9: "self-swap", 10: "venue swap", 11: "idle skim", 12: "partial recenter",
};

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
const call = (to, data) => rpc("eth_call", [{ to, data }, "latest"]);

/** signed int from a 64-hex-char slot (two's complement int256 encoding). */
function sint(slot) {
  let v = BigInt("0x" + slot);
  if (v >= 1n << 255n) v -= 1n << 256n;
  return v;
}
const hexInt = (h) => Number(BigInt(h));
const f18 = (x) => Number(x) / 1e18;

async function main() {
  // block window from the chain's own block rate
  const latest = await rpc("eth_getBlockByNumber", ["latest", false]);
  const latestNum = hexInt(latest.number);
  const past = await rpc("eth_getBlockByNumber", [
    "0x" + Math.max(latestNum - 50_000, EARLIEST).toString(16), false,
  ]);
  const rate =
    (latestNum - hexInt(past.number)) /
    Math.max(hexInt(latest.timestamp) - hexInt(past.timestamp), 1);
  const fromBlock = Math.max(Math.floor(latestNum - HOURS * 3600 * rate), EARLIEST);
  const fromHex = "0x" + fromBlock.toString(16);
  const ids = POOLS.map(([, id]) => id);

  // logs: swaps (window) · liquidity mods (FULL history — band reconstruction) · vault events (window)
  const swaps = await rpc("eth_getLogs", [
    { address: PM, fromBlock: fromHex, toBlock: "latest", topics: [T_SWAP, ids] },
  ]);
  const mods = await rpc("eth_getLogs", [
    { address: PM, fromBlock: "0x" + EARLIEST.toString(16), toBlock: "latest", topics: [T_ML, ids] },
  ]);
  const vaultLogs = await rpc("eth_getLogs", [
    { address: VAULT, fromBlock: fromHex, toBlock: "latest", topics: [[T_DEPOSIT, T_WITHDRAW, T_FEES, T_STRAT], ids] },
  ]);

  // wWETH/USD (best-effort — falls back to wWETH units)
  let ethUsd = 0;
  try {
    const gt = await (
      await fetch(`https://api.geckoterminal.com/api/v2/networks/robinhood/tokens/${WWETH}`, {
        headers: { accept: "application/json" },
      })
    ).json();
    ethUsd = Number(gt?.data?.attributes?.price_usd ?? 0);
  } catch { /* keep 0 */ }
  const usd = (weth) =>
    ethUsd ? `$${(weth * ethUsd).toFixed(weth * ethUsd < 10 ? 2 : 0)}` : `${weth.toFixed(5)}wETH`;

  const S = new Map(
    POOLS.map(([sym, id, q0]) => [id.toLowerCase(), {
      sym, q0, swaps: 0, vol: 0, router: 0, traders: new Set(), big: null,
      feeLo: Infinity, feeHi: 0, fees: 0, depN: 0, dep: 0, wdN: 0, wd: 0,
      actions: {}, bands: new Map(), praw: 0, fee: undefined, nav: undefined, tick: 0,
    }]),
  );

  // live state per pool: slot0 (tick + spot for valuation), dynamic fee, NAV
  for (const [, id] of POOLS) {
    const s = S.get(id.toLowerCase());
    try {
      const slot = await call(STATE_VIEW, "0xc815641c" + id.slice(2)); // getSlot0(bytes32)
      const d = slot.slice(2);
      const sqrtP = Number(BigInt("0x" + d.slice(0, 64)));
      s.tick = Number(sint(d.slice(64, 128)));
      s.praw = (sqrtP / 2 ** 96) ** 2; // raw token1 per token0
      s.fee = Number(BigInt(await call(HOOK, "0x04cfce0a" + id.slice(2)))) / 10_000;
      s.nav = f18(BigInt(await call(VAULT, "0x1e5f9404" + id.slice(2) + "0".repeat(64))));
    } catch { /* render as — */ }
  }
  /** value (amount0, amount1) in wWETH via the pool's own spot. */
  const inWeth = (s, a0, a1) =>
    s.q0 ? a0 + (s.praw ? a1 / s.praw : 0) : a1 + a0 * s.praw;

  for (const l of swaps) {
    const s = S.get(l.topics[1].toLowerCase());
    if (!s) continue;
    const d = l.data.slice(2);
    const a0 = Math.abs(f18(sint(d.slice(0, 64))));
    const a1 = Math.abs(f18(sint(d.slice(64, 128))));
    const wethLeg = s.q0 ? a0 : a1; // volume = the wWETH leg (exact)
    const swapFee = Number(BigInt("0x" + d.slice(320, 384))) / 10_000;
    const sender = ("0x" + l.topics[2].slice(-40)).toLowerCase();
    s.swaps++; s.vol += wethLeg;
    s.feeLo = Math.min(s.feeLo, swapFee); s.feeHi = Math.max(s.feeHi, swapFee);
    if (sender === ROUTER) s.router++;
    s.traders.add(sender);
    if (!s.big || wethLeg > s.big.weth) s.big = { weth: wethLeg, tx: l.transactionHash };
  }

  for (const l of mods) {
    const s = S.get(l.topics[1].toLowerCase());
    if (!s) continue;
    const d = l.data.slice(2);
    const k = `${sint(d.slice(0, 64))}:${sint(d.slice(64, 128))}`;
    s.bands.set(k, (s.bands.get(k) ?? 0n) + sint(d.slice(128, 192)));
  }

  for (const l of vaultLogs) {
    const s = S.get(l.topics[1].toLowerCase());
    if (!s) continue;
    const d = l.data.slice(2);
    const t0 = l.topics[0];
    if (t0 === T_DEPOSIT || t0 === T_WITHDRAW) {
      const v = inWeth(s, f18(BigInt("0x" + d.slice(0, 64))), f18(BigInt("0x" + d.slice(64, 128))));
      if (t0 === T_DEPOSIT) { s.depN++; s.dep += v; } else { s.wdN++; s.wd += v; }
    } else if (t0 === T_FEES) {
      s.fees += inWeth(s, f18(BigInt("0x" + d.slice(0, 64))), f18(BigInt("0x" + d.slice(64, 128))));
    } else if (t0 === T_STRAT) {
      const kind = KIND[Number(BigInt("0x" + d.slice(0, 64)))] ?? "?";
      s.actions[kind] = (s.actions[kind] ?? 0) + 1;
    }
  }

  // totals + message
  const rows = [...S.values()].sort((a, b) => b.vol - a.vol);
  const tot = (f) => rows.reduce((x, r) => x + f(r), 0);
  const allTraders = new Set(rows.flatMap((r) => [...r.traders]));
  const actionsTotal = {};
  for (const r of rows) for (const [k, n] of Object.entries(r.actions))
    actionsTotal[k] = (actionsTotal[k] ?? 0) + n;

  const L = [];
  L.push(`🟢 <b>FERA — last ${HOURS}h</b>`);
  L.push(`<b>${tot((r) => r.swaps)}</b> swaps · <b>${usd(tot((r) => r.vol))}</b> vol · ${tot((r) => r.router)} via 🦄 · ${allTraders.size} traders`);
  const flows = [];
  if (tot((r) => r.fees) > 0) flows.push(`💰 fees ${usd(tot((r) => r.fees))}`);
  if (tot((r) => r.depN)) flows.push(`📥 ${tot((r) => r.depN)} dep +${usd(tot((r) => r.dep))}`);
  if (tot((r) => r.wdN)) flows.push(`📤 ${tot((r) => r.wdN)} wd −${usd(tot((r) => r.wd))}`);
  if (flows.length) L.push(flows.join(" · "));
  const acts = Object.entries(actionsTotal).filter(([k]) => k !== "init");
  if (acts.length) L.push(`🤖 keeper: ${acts.map(([k, n]) => `${k} ×${n}`).join(" · ")}`);

  for (const r of rows) {
    const live = [...r.bands.values()].filter((v) => v > 0n).length;
    const inR = [...r.bands.entries()].filter(([, v]) => v > 0n)
      .map(([k]) => k.split(":").map(Number))
      .filter(([lo, hi]) => lo <= r.tick && r.tick < hi).length;
    const range = live === 0 ? "" : inR === live ? " ✅" : inR > 0 ? ` 🟡 ${inR}/${live} in range` : " 🔴 out of range";
    L.push("");
    L.push(`<b>${r.sym}</b> — ${usd(r.vol)} vol · ${r.swaps} swaps · ${r.router} 🦄`);
    const feeNow = r.fee !== undefined ? `${r.fee.toFixed(2)}%` : "—";
    const feeRng = r.swaps ? ` (${r.feeLo.toFixed(2)}–${r.feeHi.toFixed(2)})` : "";
    L.push(`fee ${feeNow}${feeRng} · NAV ${r.nav !== undefined ? usd(r.nav) : "—"}${range}`);
    const bits = [];
    if (r.big) bits.push(`big <a href="${EXPLORER}/tx/${r.big.tx}">${usd(r.big.weth)}</a>`);
    if (r.fees > 0) bits.push(`fees ${usd(r.fees)}`);
    if (r.depN) bits.push(`+${r.depN} dep ${usd(r.dep)}`);
    if (r.wdN) bits.push(`−${r.wdN} wd ${usd(r.wd)}`);
    const ra = Object.entries(r.actions).filter(([k]) => k !== "init");
    if (ra.length) bits.push(`🤖 ${ra.map(([k, n]) => (n > 1 ? `${k} ×${n}` : k)).join(", ")}`);
    if (bits.length) L.push(bits.join(" · "));
  }
  L.push("");
  L.push(`<a href="${EXPLORER}/address/${VAULT}">vault</a> · block ${latestNum}`);
  const text = L.join("\n");

  const token = process.env.TELEGRAM_BOT_TOKEN;
  const chat = process.env.TELEGRAM_CHAT_ID;
  if (token && chat) {
    const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text, parse_mode: "HTML", disable_web_page_preview: true }),
    });
    const j = await res.json();
    if (!j.ok) throw new Error(`telegram: ${j.description}`);
    console.log("digest sent to Telegram");
  } else {
    console.log("(dry run — set TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID to send)\n");
    console.log(text.replace(/<[^>]+>/g, ""));
  }
}

main().catch((e) => { console.error(e); process.exit(1); });

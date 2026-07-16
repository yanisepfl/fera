/**
 * Canonical legal content for FERA — single source for BOTH the on-site routes
 * (/legal/terms, /legal/privacy, /legal/risk) and the generated PDFs
 * (public/legal/*.pdf via scripts/generate-legal-pdfs.mjs).
 *
 * FRAMING (load-bearing, do not drift): FERA is NOT a company. There is NO legal
 * entity, NO registered address, NO jurisdiction claim. Refer only to "FERA", "the
 * Protocol", "the interface", and the pre-incorporation / experimental-software posture.
 * This is not legal advice and not a substitute for review by qualified counsel before
 * FERA incorporates or lists any real-world asset.
 */

export interface LegalSection {
  heading: string;
  /** Paragraphs and/or bullet groups. A string is a paragraph; string[] is a bullet list. */
  body: Array<string | string[]>;
}

export interface LegalDoc {
  id: "terms" | "privacy" | "risk";
  title: string;
  /** Short descriptor for <title>/OG. */
  summary: string;
  sections: LegalSection[];
}

/** ToS version. Bump when any legal text below changes materially — a new version
 *  invalidates prior acceptances and re-prompts the signature gate. Date-based. */
export const LEGAL_VERSION = "2026-07-16";

/** When the documents were last updated (human-facing). */
export const LEGAL_UPDATED = "16 July 2026";

const EXPERIMENTAL_NOTE =
  "FERA is pre-incorporation, experimental software provided on an “as is” and “as available” basis. It has not completed a third-party security audit. Nothing here is an offer, solicitation, or recommendation, and nothing here is financial, investment, legal, or tax advice (NFA).";

export const TERMS: LegalDoc = {
  id: "terms",
  title: "Terms of Service",
  summary:
    "The terms governing your use of the FERA interface — a non-custodial front-end to experimental, unaudited smart contracts.",
  sections: [
    {
      heading: "1. Acceptance of these terms",
      body: [
        "These Terms of Service (the “Terms”) govern your access to and use of the FERA web interface (the “interface”) and the FERA protocol smart contracts (the “Protocol”). By connecting a wallet, signing the acceptance message, or otherwise using the interface, you agree to these Terms, the Privacy Policy, and the Risk Disclosure. If you do not agree, do not use the interface.",
        EXPERIMENTAL_NOTE,
        "FERA is not a company. There is no legal entity, registered office, or jurisdiction behind “FERA” at this time. These Terms are provided by the pre-incorporation project and may be superseded by terms issued by a future legal entity.",
      ],
    },
    {
      heading: "2. The interface is non-custodial",
      body: [
        "The interface is a convenience front-end. It never takes custody of your assets, never holds your private keys, and cannot move, freeze, or recover your funds. Every transaction is initiated by you and signed by your own wallet. Your assets move only between your wallet and the on-chain Protocol contracts.",
        "The real money-path is the Protocol’s audited-in-future smart contracts on Robinhood Chain, not this interface. You can interact with those contracts directly, without this interface, and you remain free to do so.",
      ],
    },
    {
      heading: "3. Experimental, unaudited software",
      body: [
        "The Protocol is experimental and, at the time of this version, has not been audited by an independent security firm. Smart contracts can contain bugs, economic flaws, or vulnerabilities that lead to partial or total loss of deposited assets. You use the interface and the Protocol entirely at your own risk.",
        "The Protocol’s parameters — including fee schedules, the dynamic fee, liquidity ranges, risk levels, emissions, and keeper behavior — are experimental and may change. There is no guarantee of any return, yield, or performance, and past or illustrative figures are not indicative of future results.",
      ],
    },
    {
      heading: "4. No warranty",
      body: [
        "The interface and the Protocol are provided “as is” and “as available”, without warranties of any kind, express or implied, including merchantability, fitness for a particular purpose, title, and non-infringement. FERA does not warrant that the interface will be uninterrupted, timely, secure, or error-free, or that data shown (including market data sourced from third parties such as GeckoTerminal) is accurate or complete.",
      ],
    },
    {
      heading: "5. Limitation of liability",
      body: [
        "To the maximum extent permitted by applicable law, the FERA project, its contributors, and its maintainers will not be liable for any indirect, incidental, special, consequential, or exemplary damages, or for any loss of profits, assets, tokens, or data, arising out of or related to your use of (or inability to use) the interface or the Protocol — including losses from smart-contract exploits, market movements, impermanent loss, failed or front-run transactions, or keeper failure — even if advised of the possibility of such damages.",
        "You are solely responsible for your own transactions, wallet security, tax obligations, and compliance with the laws that apply to you.",
      ],
    },
    {
      heading: "6. Eligibility and your responsibility",
      body: [
        "You are responsible for determining whether your use of the interface and the Protocol is lawful in your jurisdiction, and for complying with all laws, sanctions, and regulations that apply to you. Access to the underlying blockchain and the Protocol contracts is permissionless and not geographically restricted by the Protocol itself; your eligibility to use them is your responsibility.",
        "The interface may, at its discretion and for any reason (including legal or compliance considerations), restrict, condition, or withdraw access to some or all of its features — for example, gating liquidity provision into tokenized-equity (RWA) pools by region. Such interface-level restrictions do not affect the permissionless nature of the on-chain contracts.",
      ],
    },
    {
      heading: "7. Prohibited use",
      body: [
        "You agree not to use the interface to violate any law; to circumvent sanctions; to launder proceeds of crime; to infringe others’ rights; to interfere with, overload, or attack the interface or its data sources; or to misrepresent the interface as being operated by, or affiliated with, any third party.",
        "FERA is built on Robinhood Chain but is not affiliated with, endorsed by, or sponsored by Robinhood. “Robinhood” is used only to identify the chain the Protocol’s pools live on.",
      ],
    },
    {
      heading: "8. Intellectual property and open source",
      body: [
        "The Protocol and interface source are published publicly. Your use of any open-source components is governed by their respective licenses. These Terms do not grant you rights in any FERA name or mark beyond what those licenses provide.",
      ],
    },
    {
      heading: "9. Changes to these terms",
      body: [
        "These Terms may be updated. Material changes are published as a new version, identified by the version string shown at the top of the acceptance gate. Continued use after a new version is published, and re-acceptance where prompted, constitutes acceptance of the updated Terms.",
      ],
    },
    {
      heading: "10. Record of acceptance",
      body: [
        "When you accept these Terms, the interface asks your wallet to sign a message that records the Terms version, a reference/hash of the documents, your wallet address, a nonce, and a timestamp. That signed message and its signature may be stored as a record of your acceptance. Signing does not create a blockchain transaction and does not cost gas.",
      ],
    },
  ],
};

export const PRIVACY: LegalDoc = {
  id: "privacy",
  title: "Privacy Policy",
  summary:
    "What limited data the FERA interface handles — and, just as importantly, what it does not collect.",
  sections: [
    {
      heading: "1. Scope",
      body: [
        "This Privacy Policy explains how the FERA interface handles information. It covers the interface only; it does not cover the public blockchain, your wallet provider, or any third-party site the interface links to. FERA is pre-incorporation and does not operate as a data-collecting business.",
      ],
    },
    {
      heading: "2. What the interface does not collect",
      body: [
        "The interface does not require an account, email, name, or password. It does not take custody of assets, and it never has access to your private keys or seed phrase.",
        "The interface does not sell personal data. The Permissions-Policy served with the interface disables camera, microphone, geolocation, and interest-cohort (FLoC) features.",
      ],
    },
    {
      heading: "3. What is processed, and why",
      body: [
        "Public wallet address: when you connect a wallet, your public address is processed in your browser to read on-chain state and to display your positions. It is inherently public on the blockchain.",
        "Terms acceptance record: if you accept the Terms, the signed acceptance message, its signature, your public address, the Terms version, and a timestamp may be stored to evidence acceptance. A best-effort source IP and user-agent may be recorded alongside it as an anti-abuse and audit measure.",
        "Technical data: standard request metadata (such as IP address) may be processed transiently by hosting and API infrastructure to serve requests, apply rate limits, and protect against abuse.",
        "Market data: pool and price data are fetched from third-party sources (e.g. GeckoTerminal). Your requests for that data are subject to those providers’ own terms and privacy practices.",
      ],
    },
    {
      heading: "4. Local storage",
      body: [
        "The interface may store small values in your browser (for example, a flag that you accepted a given Terms version, and wallet-connection state) so it does not prompt you unnecessarily. You can clear this at any time via your browser.",
      ],
    },
    {
      heading: "5. Blockchain is permanent and public",
      body: [
        "Transactions you sign are recorded permanently on a public blockchain and cannot be altered or deleted by FERA or anyone else. Do not use the interface to transact if you need that activity to remain private or reversible.",
      ],
    },
    {
      heading: "6. Data retention and your choices",
      body: [
        "Acceptance records are retained as long as needed to evidence your acceptance and to meet legitimate legal or compliance needs. Because FERA is pre-incorporation and non-custodial, it holds little personal data; where a future FERA legal entity is established, this Policy will be updated to describe your rights and how to exercise them.",
      ],
    },
    {
      heading: "7. Changes",
      body: [
        "This Policy may be updated; the “last updated” date at the top reflects the current version.",
      ],
    },
  ],
};

export const RISK: LegalDoc = {
  id: "risk",
  title: "Risk Disclosure",
  summary:
    "The concrete ways you can lose money using FERA. Read this before you deposit.",
  sections: [
    {
      heading: "Read this first",
      body: [
        "Providing liquidity through the FERA Protocol carries a real risk of losing some or all of your assets. The following is not exhaustive. If you do not understand a risk below, do not deposit.",
        EXPERIMENTAL_NOTE,
      ],
    },
    {
      heading: "1. Risk of total loss",
      body: [
        "You can lose everything you deposit. Crypto assets are highly volatile, and the Protocol is experimental software. Only provide assets you can afford to lose entirely.",
      ],
    },
    {
      heading: "2. Smart-contract and exploit risk",
      body: [
        "The Protocol has not been independently audited at this version. Bugs, economic design flaws, upgrade or admin-key issues, oracle failures, or exploits could drain or lock funds. An audit, if completed, reduces but never eliminates this risk.",
      ],
    },
    {
      heading: "3. Impermanent loss and LVR on volatile assets",
      body: [
        "FERA vaults provide concentrated liquidity, initially on volatile meme-coin pairs. When prices move, liquidity providers suffer impermanent loss and loss-versus-rebalancing (LVR): the position is systematically bought from at stale prices by arbitrageurs. On sharp, one-sided moves this can substantially exceed the fees earned, so a managed FERA position can end up worth less than simply holding the tokens.",
      ],
    },
    {
      heading: "4. No guaranteed return; fees are variable",
      body: [
        "Trading fees are real income but are variable and never guaranteed. In quiet markets fees may be negligible. There is no fixed yield, no promised APR, and any illustrative figure shown in the interface is not a prediction.",
      ],
    },
    {
      heading: "5. Dynamic fee and range management",
      body: [
        "The Protocol adjusts the swap fee and the active liquidity range automatically based on market conditions. These mechanisms are experimental. They may misjudge conditions, lag fast moves, or interact with the market in ways that reduce your returns or increase your losses.",
      ],
    },
    {
      heading: "6. Keeper and infrastructure dependence",
      body: [
        "Rebalancing, fee updates, and emissions rely on off-chain keepers and infrastructure. If keepers fail, are delayed, are censored, or act adversarially, ranges may drift, rebalances may be front-run or sandwiched (MEV), and performance may degrade. Chain congestion, RPC outages, or data-source failures can also affect the interface and the Protocol.",
      ],
    },
    {
      heading: "7. Pause and access changes",
      body: [
        "Deposits and certain risky actions may be paused to protect funds if something appears wrong. Protocol parameters may change. The interface may restrict or withdraw access to features (for example by region for tokenized-equity pools). Withdrawals of principal are designed never to be frozen, but the mechanism is still experimental software.",
      ],
    },
    {
      heading: "8. Emissions and token risk",
      body: [
        "Any FERA/esFERA emissions are experimental incentives, not a promise of value. Emission schedules, vesting, and any early-exit haircut may change, and the market value of emitted tokens can fall to zero.",
      ],
    },
    {
      heading: "9. Tokenized real-world assets (RWA)",
      body: [
        "Pools referencing tokenized equities carry additional risks: reliance on the token issuer, market-hours and oracle mechanics, corporate actions, and jurisdictional restrictions. The interface may gate liquidity provision into such pools by region; your eligibility and compliance remain your responsibility.",
      ],
    },
    {
      heading: "10. Regulatory and tax risk",
      body: [
        "The legal and tax treatment of liquidity provision, emissions, and tokenized assets is uncertain and varies by jurisdiction and may change. You are responsible for your own compliance and taxes.",
      ],
    },
    {
      heading: "11. Irreversibility",
      body: [
        "Blockchain transactions are final. A mistaken, front-run, or exploited transaction generally cannot be reversed, and no one can recover lost funds on your behalf.",
      ],
    },
  ],
};

export const LEGAL_DOCS: Record<LegalDoc["id"], LegalDoc> = {
  terms: TERMS,
  privacy: PRIVACY,
  risk: RISK,
};

export const LEGAL_ORDER: LegalDoc["id"][] = ["terms", "privacy", "risk"];

/**
 * Deterministic canonical plain-text of ALL legal docs, in a fixed order. The ToS gate
 * hashes this (SHA-256) so the signed acceptance message commits to the exact wording
 * the user was shown. The PDF/HTML generator uses the same structure, so the on-site
 * routes, the PDFs, and the signed hash all describe the same content.
 */
export function canonicalLegalText(): string {
  const parts: string[] = [`FERA Legal Documents — version ${LEGAL_VERSION}`];
  for (const id of LEGAL_ORDER) {
    const doc = LEGAL_DOCS[id];
    parts.push(`\n## ${doc.title}`);
    for (const s of doc.sections) {
      parts.push(`\n### ${s.heading}`);
      for (const b of s.body) {
        parts.push(Array.isArray(b) ? b.map((x) => `- ${x}`).join("\n") : b);
      }
    }
  }
  return parts.join("\n");
}

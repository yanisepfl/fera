import { ImageResponse } from "next/og";

/**
 * Branded share card (Open Graph + Twitter). Self-contained: solid brand colors and
 * the bundled default font, no external assets, so shared FERA links unfurl with a
 * real preview instead of a blank card. Satori-safe (every container is flex).
 */
export const alt = "FERA - earn like a market maker, on Robinhood Chain";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: 80,
          backgroundColor: "#0a0a0b",
          backgroundImage:
            "linear-gradient(150deg, rgba(46,207,136,0.14) 0%, rgba(46,207,136,0) 48%)",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              width: 56,
              height: 56,
              borderRadius: 14,
              border: "1px solid rgba(231,184,75,0.35)",
              backgroundColor: "rgba(231,184,75,0.12)",
              color: "#e7b84b",
              fontSize: 34,
              fontWeight: 700,
            }}
          >
            F
          </div>
          <div
            style={{
              display: "flex",
              fontSize: 40,
              fontWeight: 700,
              letterSpacing: -1,
              color: "#e7b84b",
            }}
          >
            FERA
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
          <div
            style={{
              display: "flex",
              fontSize: 72,
              fontWeight: 700,
              lineHeight: 1.05,
              letterSpacing: -2,
              color: "#f4f4f6",
              maxWidth: 900,
            }}
          >
            Earn like a market maker.
          </div>
          <div
            style={{
              display: "flex",
              fontSize: 30,
              lineHeight: 1.35,
              color: "#a9a9b4",
              maxWidth: 940,
            }}
          >
            Deposit into a vault that provides and auto-manages the liquidity - and
            earn the trading fees. On meme coins and stocks.
          </div>
        </div>

        <div
          style={{
            display: "flex",
            fontSize: 22,
            letterSpacing: 1,
            textTransform: "uppercase",
            color: "#6e6e79",
          }}
        >
          Built on Robinhood Chain · Meme coins now · Stocks soon
        </div>
      </div>
    ),
    { ...size }
  );
}

import { ImageResponse } from "next/og";

/**
 * Branded share card (Open Graph + Twitter). Self-contained: solid brand colors and
 * the bundled default font, no external assets, so shared FERA links unfurl with a
 * real preview instead of a blank card. Satori-safe (every container is flex).
 */
export const alt = "FERA - put your meme coins to work, on Robinhood Chain";
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
            "linear-gradient(150deg, rgba(231,184,75,0.12) 0%, rgba(231,184,75,0) 48%)",
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
Put your meme coins to work.
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
Deposit your coins in a vault that earns the trading fees from all their
            volatility. Meme coins now, tokenized stocks soon.
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

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
          backgroundColor: "#080b0a",
          backgroundImage:
            "linear-gradient(150deg, rgba(47,224,138,0.12) 0%, rgba(47,224,138,0) 48%)",
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
              border: "1px solid rgba(47,224,138,0.35)",
              backgroundColor: "rgba(47,224,138,0.12)",
            }}
          >
            <svg width={34} height={34} viewBox="0 0 100 100" fill="#2fe08a">
              <path d="M20 80 C24 62 30 47 38 36 C35 51 31 67 28 84 Z" />
              <path d="M39 83 C44 61 51 43 61 28 C56 47 50 67 46 87 Z" />
              <path d="M59 85 C65 59 73 39 85 20 C78 44 70 67 66 89 Z" />
            </svg>
          </div>
          <div
            style={{
              display: "flex",
              fontSize: 40,
              fontWeight: 700,
              letterSpacing: -1,
              color: "#2fe08a",
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
              color: "#ecf3ef",
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
              color: "#9aa8a1",
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
            color: "#616f68",
          }}
        >
          Built on Robinhood Chain · Meme coins now · Stocks soon
        </div>
      </div>
    ),
    { ...size }
  );
}

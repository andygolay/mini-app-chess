import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Chess on Movement",
  description: "Play chess against an AI opponent - all moves verified on-chain",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}


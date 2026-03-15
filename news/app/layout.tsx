import type { Metadata } from "next";
import CloudSyncProvider from "@/components/CloudSyncProvider";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "MeshNews — mesh crisis → local stories",
  description:
    "Hackathon demo: peer reports, deduped stories, recommendations, mock escalation",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        <CloudSyncProvider>{children}</CloudSyncProvider>
      </body>
    </html>
  );
}

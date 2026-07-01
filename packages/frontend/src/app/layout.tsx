import type { Metadata } from 'next';
import './globals.css';
import { Web3Provider } from '@/providers/Web3Provider';

export const metadata: Metadata = {
  title: 'LiquidLP — Unlock Your LP Positions',
  description: 'Borrow against LP positions without removing liquidity',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Web3Provider>{children}</Web3Provider>
      </body>
    </html>
  );
}

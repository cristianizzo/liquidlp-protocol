'use client';

export default function Dashboard() {
  return (
    <main className="min-h-screen p-8">
      <div className="max-w-7xl mx-auto">
        <h1 className="text-4xl font-bold mb-2">LiquidLP</h1>
        <p className="text-gray-400 mb-8">Unlock your LP positions. Borrow without removing liquidity.</p>

        {/* Protocol Stats */}
        <div className="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
          <StatCard label="Total Value Locked" value="$0" />
          <StatCard label="Total Borrowed" value="$0" />
          <StatCard label="Active Positions" value="0" />
          <StatCard label="Supported Pools" value="0" />
        </div>

        {/* User Positions */}
        <section>
          <h2 className="text-2xl font-semibold mb-4">Your Positions</h2>
          <div className="rounded-lg border border-[var(--border)] bg-[var(--card)] p-8 text-center text-gray-500">
            Connect your wallet to view positions
          </div>
        </section>
      </div>
    </main>
  );
}

function StatCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-[var(--border)] bg-[var(--card)] p-4">
      <p className="text-sm text-gray-400">{label}</p>
      <p className="text-2xl font-bold mt-1">{value}</p>
    </div>
  );
}

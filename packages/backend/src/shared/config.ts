export const config = {
  port: Number(process.env.PORT) || 3001,
  database: {
    url: process.env.DATABASE_URL || 'postgresql://liquidlp:localdev@localhost:5432/liquidlp',
  },
  redis: {
    url: process.env.REDIS_URL || 'redis://localhost:6379',
  },
  rpc: {
    ethereum: process.env.ETH_RPC_URL || 'https://eth.llamarpc.com',
    base: process.env.BASE_RPC_URL || 'https://mainnet.base.org',
    arbitrum: process.env.ARB_RPC_URL || 'https://arb1.arbitrum.io/rpc',
    bsc: process.env.BSC_RPC_URL || 'https://bsc-dataseed.binance.org',
    polygon: process.env.POLYGON_RPC_URL || 'https://polygon-rpc.com',
  },
  alerts: {
    telegramBotToken: process.env.TELEGRAM_BOT_TOKEN,
    telegramChatId: process.env.TELEGRAM_CHAT_ID,
    discordWebhookUrl: process.env.DISCORD_WEBHOOK_URL,
  },
} as const;

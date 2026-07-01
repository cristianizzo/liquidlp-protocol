import { config } from '../../shared/config';
import { logger } from '../../shared/logger';

export type AlertSeverity = 'info' | 'warning' | 'critical';

export const alerter = {
  async send(message: string, severity: AlertSeverity = 'info') {
    logger.warn({ severity }, message);

    // Telegram
    if (config.alerts.telegramBotToken && config.alerts.telegramChatId) {
      try {
        const url = `https://api.telegram.org/bot${config.alerts.telegramBotToken}/sendMessage`;
        await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            chat_id: config.alerts.telegramChatId,
            text: `[${severity.toUpperCase()}] LiquidLP: ${message}`,
          }),
        });
      } catch (err) {
        logger.error({ err }, 'Failed to send Telegram alert');
      }
    }

    // Discord
    if (config.alerts.discordWebhookUrl) {
      try {
        await fetch(config.alerts.discordWebhookUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            content: `**[${severity.toUpperCase()}]** LiquidLP: ${message}`,
          }),
        });
      } catch (err) {
        logger.error({ err }, 'Failed to send Discord alert');
      }
    }
  },
};

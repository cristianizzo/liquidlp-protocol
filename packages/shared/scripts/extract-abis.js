#!/usr/bin/env node

/**
 * Extract ABIs from Foundry build output and write them to the shared package.
 * Run after `forge build` to sync ABIs.
 *
 * Usage: node scripts/extract-abis.js
 */

const fs = require('fs');
const path = require('path');

const CONTRACTS_OUT = path.resolve(__dirname, '../../contracts/out');
const ABIS_DIR = path.resolve(__dirname, '../src/abis');

const CONTRACT_NAMES = [
  'ProtocolCore',
  'PositionManager',
  'LendingEngine',
  'LiquidationEngine',
  'FeeCollector',
  'LPOracleHub',
  'Market',
  'MarketFactory',
  'MarketRegistry',
  'InterestRateModel',
  'Router',
  'PositionViewer',
  'CircuitBreaker',
  'RiskManager',
  'PoolHealthMonitor',
  'EmergencyModule',
];

// Ensure output directory exists
if (!fs.existsSync(ABIS_DIR)) {
  fs.mkdirSync(ABIS_DIR, { recursive: true });
}

let extracted = 0;

for (const name of CONTRACT_NAMES) {
  const artifactPath = path.join(CONTRACTS_OUT, `${name}.sol`, `${name}.json`);

  if (!fs.existsSync(artifactPath)) {
    console.warn(`  SKIP: ${name} (not found at ${artifactPath})`);
    continue;
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf-8'));
  const abi = artifact.abi;

  if (!abi) {
    console.warn(`  SKIP: ${name} (no ABI in artifact)`);
    continue;
  }

  const outputPath = path.join(ABIS_DIR, `${name}.json`);
  fs.writeFileSync(outputPath, JSON.stringify(abi, null, 2));
  console.log(`  OK: ${name} (${abi.length} entries)`);
  extracted++;
}

console.log(`\nExtracted ${extracted}/${CONTRACT_NAMES.length} ABIs to ${ABIS_DIR}`);

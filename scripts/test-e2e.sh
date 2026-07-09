#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ANVIL_URL="http://localhost:8545"
MAX_WAIT=60

echo -e "${YELLOW}=== Aurelia E2E Test Runner ===${NC}"
echo ""

# Check .env exists
if [ ! -f .env ]; then
  echo -e "${RED}Error: .env file not found. Copy .env.example and set ETH_RPC_URL${NC}"
  exit 1
fi

# --- Step 1: Start Anvil fork ---
echo -e "${YELLOW}[Step 1] Starting Anvil fork via Docker...${NC}"
docker compose up -d anvil

echo -n "  Waiting for Anvil"
for i in $(seq 1 $MAX_WAIT); do
  if curl -s -X POST "$ANVIL_URL" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    2>/dev/null | grep -q "result"; then
    echo -e " ${GREEN}ready!${NC}"
    break
  fi
  echo -n "."
  sleep 1
  if [ "$i" -eq "$MAX_WAIT" ]; then
    echo -e " ${RED}timeout!${NC}"
    docker compose logs anvil --tail 20
    exit 1
  fi
done

# --- Step 2: Deploy contracts to fork ---
echo ""
echo -e "${YELLOW}[Step 2] Deploying contracts to Anvil fork...${NC}"
cd packages/contracts
forge script script/Deploy.s.sol --rpc-url "$ANVIL_URL" --broadcast
echo -e "  ${GREEN}Contracts deployed!${NC}"

# --- Step 3: Run tests ---
echo ""
echo -e "${YELLOW}[Step 3] Running tests...${NC}"
echo ""

TEST_SUITE="${1:-all}"

case "$TEST_SUITE" in
  unit)
    echo -e "${YELLOW}  Running unit tests (no fork needed)${NC}"
    forge test --match-path 'test/unit/**' -vvv
    ;;
  fork)
    echo -e "${YELLOW}  Running fork tests${NC}"
    forge test --match-path 'test/fork/**' --fork-url "$ANVIL_URL" -vvv
    ;;
  e2e)
    echo -e "${YELLOW}  Running E2E tests${NC}"
    forge test --match-path 'test/e2e/**' --fork-url "$ANVIL_URL" -vvv
    ;;
  security)
    echo -e "${YELLOW}  Running security tests${NC}"
    forge test --match-path 'test/security/**' -vvv
    ;;
  all)
    echo -e "${YELLOW}  [1/5] Unit tests${NC}"
    forge test --match-path 'test/unit/**' -vvv
    echo ""
    echo -e "${YELLOW}  [2/5] Integration tests${NC}"
    forge test --match-path 'test/integration/**' -vvv
    echo ""
    echo -e "${YELLOW}  [3/5] Security tests${NC}"
    forge test --match-path 'test/security/**' -vvv
    echo ""
    echo -e "${YELLOW}  [4/5] Fork tests${NC}"
    forge test --match-path 'test/fork/**' --fork-url "$ANVIL_URL" -vvv
    echo ""
    echo -e "${YELLOW}  [5/5] E2E tests${NC}"
    forge test --match-path 'test/e2e/**' --fork-url "$ANVIL_URL" -vvv
    ;;
  *)
    echo "Usage: $0 [unit|fork|e2e|security|all]"
    exit 1
    ;;
esac

echo ""
echo -e "${GREEN}=== All tests passed ===${NC}"

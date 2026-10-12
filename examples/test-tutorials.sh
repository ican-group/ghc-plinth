#!/usr/bin/env bash
# Test the tutorial example projects, as CI does. Stages:
#
#   onchain        build examples/add, examples/lock and examples/auction
#                  with uplc-ghc and check the files they write
#   offchain-build build examples/lock-ghci, examples/lock-ghci-exp and
#                  examples/auction-ghci with a standard GHC
#   e2e            run the GHCi sessions against a Yaci DevKit devnet:
#                  lock, unlock, and the wrong-redeemer rejection; then a
#                  whole auction with its rejected bids
#
# Usage: test-tutorials.sh [onchain|offchain-build|e2e]...
# With no argument, run all stages.
#        test-tutorials.sh version
# Print the uplc-ghc release that the on-chain projects name in
# with-compiler.
#
# onchain needs that release (ghcup install plinth <version>). JOBS=n
# limits cabal to n parallel package builds (default: one per CPU).
# offchain-build needs the GHC named in examples/lock-ghci/cabal.project
# and the system LMDB and liburing libraries (liblmdb-dev and
# liburing-dev on Debian/Ubuntu).
# e2e needs docker (with compose), socat, and the offchain builds.

set -euo pipefail

EXAMPLES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVKIT_VERSION=0.12.0-beta5
DEVKIT_DIR="$HOME/.yaci-devkit"

log() { printf '\n=== %s\n' "$*"; }

# The uplc-ghc release of the on-chain projects (with-compiler:
# uplc-ghc-<version>). Fail if they do not all name the same one.
plinth_version() {
  local p v first=
  for p in add lock auction; do
    v=$(sed -n 's/^with-compiler: *uplc-ghc-//p' "$EXAMPLES_DIR/$p/cabal.project")
    if [ -z "$v" ] || { [ -n "$first" ] && [ "$v" != "$first" ]; }; then
      echo "error: add/, lock/ and auction/ must name the same uplc-ghc" \
           "release ($p/ names '$v')" >&2
      return 1
    fi
    first=$v
  done
  echo "$first"
}

# Retry a command a few times, 30s apart. Use it for the network-facing
# cabal update: hackage-security also queries hackage.haskell.org mirrors,
# and one bad mirror fails the whole command (a 403 from the dream.io
# mirror killed a CI run).
retry() {
  local tries=$1 i
  shift
  for i in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    if [ "$i" -lt "$tries" ]; then
      echo "attempt $i/$tries failed: $*; retrying in 30s" >&2
      sleep 30
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Stage: onchain
# ---------------------------------------------------------------------------

stage_onchain() {
  log "onchain: examples/add"
  ( cd "$EXAMPLES_DIR/add"
    retry 3 cabal update
    cabal build ${JOBS:+--jobs="$JOBS"}
    cabal run -v0 plinth-add
    grep -F 'addInteger' add.uplc
  )

  log "onchain: examples/lock"
  ( cd "$EXAMPLES_DIR/lock"
    cabal build ${JOBS:+--jobs="$JOBS"}
    cabal run -v0 plinth-lock
    grep -F '"type": "PlutusScriptV3"' lock.plutus
    grep -E '"cborHex": "[0-9a-f]+"' lock.plutus >/dev/null
  )

  log "onchain: examples/auction"
  ( cd "$EXAMPLES_DIR/auction"
    cabal build ${JOBS:+--jobs="$JOBS"}
    cabal run -v0 plinth-auction
    grep -F '"type": "PlutusScriptV3"' auction.plutus
  )
  log "onchain: OK"
}

# ---------------------------------------------------------------------------
# Stage: offchain-build
# ---------------------------------------------------------------------------

stage_offchain_build() {
  for project in lock-ghci lock-ghci-exp auction-ghci; do
    log "offchain-build: examples/$project"
    ( cd "$EXAMPLES_DIR/$project"
      retry 3 cabal update
      cabal build
    )
  done
  log "offchain-build: OK"
}

# ---------------------------------------------------------------------------
# Stage: e2e
# ---------------------------------------------------------------------------

# The devkit console (create-node, topup) is an interactive shell in the
# container. Drive it through a fifo that stays open for the whole stage.
CONSOLE_IN=
CONSOLE_LOG=
CONSOLE_HOLDER=

console_start() {
  local tmp
  tmp=$(mktemp -d)
  CONSOLE_IN="$tmp/in"
  CONSOLE_LOG="$tmp/log"
  mkfifo "$CONSOLE_IN"
  sleep infinity > "$CONSOLE_IN" &
  CONSOLE_HOLDER=$!
  docker compose --project-name node1 \
    -f "$DEVKIT_DIR/scripts/docker-compose.yml" \
    --env-file "$DEVKIT_DIR/config/env" \
    --env-file "$DEVKIT_DIR/config/version" \
    exec -T yaci-cli /app/yaci-cli.sh < "$CONSOLE_IN" > "$CONSOLE_LOG" 2>&1 &
}

console_send() {
  echo "$1" > "$CONSOLE_IN"
}

in_container() {
  docker exec node1-yaci-cli-1 bash -c "$1"
}

wait_for() {
  local what=$1 tries=$2 check=$3
  for _ in $(seq 1 "$tries"); do
    if eval "$check" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "timed out waiting for $what" >&2
  echo "--- console log:" >&2
  tail -30 "$CONSOLE_LOG" >&2 || true
  return 1
}

cleanup_e2e() {
  bash "$DEVKIT_DIR/scripts/stop.sh" || true
  [ -n "$CONSOLE_HOLDER" ] && kill "$CONSOLE_HOLDER" 2>/dev/null || true
  pkill -f "UNIX-LISTEN:node.sock" 2>/dev/null || true
}

# Run the tutorial GHCi session in one project directory. Prints the
# script address on stdout; fails if any part of the session misbehaves.
run_session() {
  local project=$1
  cd "$EXAMPLES_DIR/$project"
  rm -f user.skey node.sock
  cp "$EXAMPLES_DIR/lock/lock.plutus" .
  socat UNIX-LISTEN:node.sock,fork,reuseaddr TCP:127.0.0.1:3333 &
  local socat_pid=$!
  sleep 1

  local addresses wallet_addr script_addr
  addresses=$(cabal repl -v0 <<'EOF'
putStrLn . bech32 =<< walletAddress
putStrLn . bech32 =<< scriptAddress
EOF
  )
  wallet_addr=$(echo "$addresses" | sed -n 1p)
  script_addr=$(echo "$addresses" | sed -n 2p)

  console_send "topup $wallet_addr 1000"
  wait_for "topup of $wallet_addr" 30 \
    "in_container 'cardano-cli conway query utxo --address $wallet_addr --testnet-magic 42' | grep -q lovelace"

  local session
  session=$(cabal repl -v0 2>&1 <<'EOF'
import Control.Concurrent (threadDelay)
lockFunds 10_000_000 1234
threadDelay 4_000_000
showUtxos =<< scriptAddress
unlockFunds 1234
threadDelay 4_000_000
showUtxos =<< walletAddress
lockFunds 10_000_000 1234
threadDelay 4_000_000
unlockFunds 4321
EOF
  ) || true
  echo "--- $project session:" >&2
  echo "$session" >&2

  kill "$socat_pid" 2>/dev/null || true

  # The lock landed with its inline datum, the unlock brought back
  # close to 10 ada, and the wrong redeemer was rejected with the
  # validator's own trace message.
  echo "$session" | grep -q 'lovelace, datum ScriptDataNumber 1234'
  echo "$session" | grep -qE '#[0-9]+: 96[0-9]{5} lovelace'
  echo "$session" | grep -q 'wrong number'

  echo "$script_addr"
}

# Run the auction tutorial session: start, two bids, a bid that is too
# low, a fake output at the auction address, a bid after the end, and the
# payout. Fails if any step misbehaves.
run_auction_session() {
  cd "$EXAMPLES_DIR/auction-ghci"
  rm -f seller.skey alice.skey bob.skey node.sock
  cp "$EXAMPLES_DIR/auction/auction.plutus" .
  socat UNIX-LISTEN:node.sock,fork,reuseaddr TCP:127.0.0.1:3333 &
  local socat_pid=$!
  sleep 1

  local w addr
  for w in seller alice bob; do
    addr=$(echo "putStrLn . bech32 =<< walletAddress $w" | cabal repl -v0)
    console_send "topup $addr 1000"
    wait_for "topup of $w" 30 \
      "in_container 'cardano-cli conway query utxo --address $addr --testnet-magic 42' | grep -q lovelace"
  done

  local session
  session=$(cabal repl -v0 2>&1 <<'EOF'
auction <- startAuction 50 90
showAuction auction
bid auction alice 100
showAuction auction
bid auction bob 150
showAuction auction
showWallet alice
bid auction alice 120
fakeBid auction bob 1000
showAuction auction
waitForEnd auction
bid auction alice 200
payout auction
showWallet bob
showWallet seller
EOF
  ) || true
  echo "--- auction-ghci session:" >&2
  echo "$session" >&2

  kill "$socat_pid" 2>/dev/null || true

  # Each state of the auction, as the tutorial shows it.
  echo "$session" | grep -q 'the item + 2 ada, no bid yet  <- the auction'
  echo "$session" | grep -q 'the item + 100 ada, highest bid: alice, 100 ada  <- the auction'
  echo "$session" | grep -q 'the item + 150 ada, highest bid: bob, 150 ada  <- the auction'
  # Alice got her 100 ada back.
  echo "$session" | grep -qE '^[0-9a-f]{8}\.\.\.#1: 100 ada$'
  # The low bid failed in the validator, the fake output is not the
  # auction, and the late bid failed in the ledger.
  echo "$session" | grep -q 'bid too low'
  echo "$session" | grep -q '5 ada, highest bid: bob, 1000 ada  (no item: not the auction)'
  echo "$session" | grep -q 'OutsideValidityIntervalUTxO'
  # Bob has the item, the seller has the 150 ada.
  echo "$session" | grep -qE ': the item \+ 2 ada$'
  echo "$session" | grep -qE ': 150 ada$'
}

stage_e2e() {
  log "e2e: install Yaci DevKit $DEVKIT_VERSION"
  if ! grep -qs "$DEVKIT_VERSION" "$DEVKIT_DIR/config/version"; then
    rm -rf "$DEVKIT_DIR"
    curl --proto '=https' --tlsv1.2 -LsSf https://devkit.yaci.xyz/install.sh \
      | bash -s -- "$DEVKIT_VERSION"
  fi

  trap cleanup_e2e EXIT
  log "e2e: start the devnet"
  bash "$DEVKIT_DIR/scripts/start.sh"
  console_start
  sleep 5
  console_send "create-node -o --start"
  wait_for "the devnet node" 60 \
    "in_container 'cardano-cli conway query tip --testnet-magic 42' | grep -q Conway"

  log "e2e: session with examples/lock-ghci"
  addr_classic=$(run_session lock-ghci | tail -1)

  log "e2e: session with examples/lock-ghci-exp"
  addr_exp=$(run_session lock-ghci-exp | tail -1)

  # Both interfaces must compute the same script address.
  [ "$addr_classic" = "$addr_exp" ]

  log "e2e: auction session with examples/auction-ghci"
  run_auction_session

  log "e2e: OK (lock script address $addr_classic)"
}

# ---------------------------------------------------------------------------

if [ "${1:-}" = version ]; then
  plinth_version
  exit
fi

stages=("$@")
[ ${#stages[@]} -eq 0 ] && stages=(onchain offchain-build e2e)
for stage in "${stages[@]}"; do
  case "$stage" in
    onchain) stage_onchain ;;
    offchain-build) stage_offchain_build ;;
    e2e) stage_e2e ;;
    *) echo "unknown stage: $stage" >&2; exit 1 ;;
  esac
done

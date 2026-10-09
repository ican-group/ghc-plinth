---
title: Lock and unlock funds on a local chain (Linux)
permalink: /tutorials/lock-and-unlock/
---
Your [first smart contract]({% link tutorials/first-smart-contract.md %}) ended
with a `.uplc` file. In this tutorial you take the next step: you put a
contract on a chain and use it.

## What you will build

The contract is a number lock. You store money in it together with a secret
number; whoever gives the same number back can take the money out.

On Cardano this shape has three parts:

- A **validator**: the on-chain program. It guards funds and answers one
  question: "may this transaction spend them?". Yours says yes only when the
  number the spender supplies equals the stored one.
- A **datum**: data stored on the chain together with the locked funds. It is
  chosen when the funds are locked. Yours is the secret number, 1234.
- A **redeemer**: data the spending transaction supplies to the validator.
  Yours is the guess.

You will write the validator in Plinth (about twenty lines), compile it with
`uplc-ghc`, and package it in the file format Cardano tools use. Then, on a
private Cardano network running on your machine, you will:

1. compute the validator's **script address** and send 10 test ada to it,
   with the datum stored alongside (the "lock" transaction);
2. spend those funds with redeemer 1234 (the "unlock" transaction);
3. try redeemer 4321 and watch the validator reject the transaction, with the
   error message your own code produced.

The conceptual map for everything below is
[From Plinth to the chain]({% link explanation/from-plinth-to-the-chain.md %}).
This tutorial walks the same path with commands.

This tutorial targets **Linux**.

## Before you start

You need:

- the setup from the
  [first tutorial]({% link tutorials/first-smart-contract.md %}): `uplc-ghc`
  and `cabal` on `PATH`;
- [Docker](https://docs.docker.com/engine/install/) with the Compose plugin,
  installed and running (check with `docker compose version` and
  `docker ps`);
- about 5 GB of free disk space for the container images;
- free TCP ports 1337, 1442, 3001, 3333, 5173, 6060, 8080, 8090, and 10000
  (the devkit maps all of them).

The local network runs in Docker containers managed by
[Yaci DevKit](https://github.com/bloxbean/yaci-devkit). Your Haskell program
runs on the host; only the chain lives in containers.

## Step 1: Create the project

Make a new directory and add the three files below.

**`cabal.project`** is the one from the first tutorial with one change: the
`ghc-plinth-plutus` block also pulls `plutus-ledger-api`, the library with the
ledger types (`ScriptContext`, `Datum`, ...) and the script serialisation
helpers:

```haskell
with-compiler: uplc-ghc
with-hc-pkg:   uplc-ghc-pkg

packages: .

repository cardano-haskell-packages
  url: https://chap.intersectmbo.org/
  secure: True
  root-keys:
    3e0cce471cf09815f930210f7827266fd09045445d65923e6d0238a6cd15126f
    443abb7fb497a134c343faf52f0b659bd7999bc06b7f63fa76dc99d631f9bea1
    a86a1f6ce86c449c46666bda44268677abf29b5b2d2eb5ec7af903ec2f117a82
    bcec67e8e99cabfa7764d75ad9b158d72bfacf70ca1d0ec8bc6b4406d1bf8413
    c00aae8461a256275598500ea0e187588c35a5d5d7454fb57eac18d9edb86a56
    d4a35cd3121aa00d18544bb0ac01c3e1691d618f462c46129271bccf39f7e8ee

index-state:
  , hackage.haskell.org 2026-08-06T04:37:23Z
  , cardano-haskell-packages 2026-08-05T05:00:53Z

-- The Plinth libraries, from the fork uplc-ghc was built against. The
-- compiler itself is built into uplc-ghc, so plutus-tx-plugin is not needed.
source-repository-package
  type: git
  location: https://github.com/input-output-hk/ghc-plinth-plutus
  tag: f89c66c51e7b382c6574fc7d7887de8ba8ced457
  subdir: plutus-tx
          plutus-core
          plutus-ledger-api

source-repository-package
  type: git
  location: https://github.com/hsyl20/cardano-base
  tag: 055ebbcc73e1cb234f1fd3fa237a4fb087130183
  subdir: cardano-crypto-class
          cardano-crypto-praos

source-repository-package
  type: git
  location: https://github.com/haskell-cryptography/blst-clib
  tag: 0fd1d38d5ceed5529ac646efae3095b493a97927

source-repository-package
  type: git
  location: https://github.com/haskell-cryptography/libsodium-clib
  tag: 985c18f75a71ff721370940666d71fda53edbb14

source-repository-package
  type: git
  location: https://github.com/haskell-cryptography/secp256k1-clib
  tag: 211b95baad422966c9e719ed70cbc189c58eaae5

package secp256k1-clib
  flags: +schnorrsig +recovery +ecdh +extrakeys

package cardano-crypto-class
  flags: +use-haskell-clibs

package cardano-crypto-praos
  flags: +use-haskell-clibs

package sodium-clib
  -- disable -fPIE: the static boot libraries are not built with it, so the
  -- link phase fails otherwise.
  configure-options: --enable-pie=no
```

Use the `ghc-plinth-plutus` commit that matches your `uplc-ghc`, as in the
first tutorial.

**Not for production.** The vendored crypto C libraries pulled in by the
`*-clib` `source-repository-package`s above have not been audited. Use this
setup for learning and experimentation only &mdash; never for contracts that
handle real funds.
{:.warning}

**`plinth-lock.cabal`** describes the executable. The `ghc-options` block is
the same as in the first tutorial:

```haskell
cabal-version: 3.0
name:          plinth-lock
version:       0.1.0.0
build-type:    Simple

executable plinth-lock
  main-is:            Main.hs
  default-language:   Haskell2010
  default-extensions: DataKinds
  build-depends:
    , base
    , plutus-tx
    , plutus-ledger-api
  ghc-options:
    -fexternal-interpreter
    -fobject-code -fno-full-laziness -fno-spec-constr
    -fno-specialise -fno-strictness -fno-unbox-small-strict-fields
    -fno-unbox-strict-fields
    -fplugin-opt Plinth.Plugin:target-version=1.1.0
```

**`Main.hs`** contains the validator and a `main` that writes it to disk in
the format `cardano-cli` expects:

```haskell
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import PlutusTx
import qualified PlutusTx.Prelude as Tx
import PlutusLedgerApi.V3
  (Datum (..), ScriptContext (..), ScriptInfo (..), getRedeemer)
import PlutusLedgerApi.Envelope (writeCodeEnvelope)

-- The on-chain rule: the transaction can spend the locked output only
-- if the redeemer equals the number stored in the datum.
lockTyped :: ScriptContext -> Bool
lockTyped ctx =
  case scriptContextScriptInfo ctx of
    SpendingScript _ (Just (Datum datum)) ->
      case (fromBuiltinData datum, fromBuiltinData redeemer) of
        (Just secret, Just guess) ->
          Tx.traceIfFalse "wrong number" (guess Tx.== (secret :: Integer))
        _ -> Tx.traceError "datum or redeemer is not an integer"
    _ -> Tx.traceError "expected a spending script with a datum"
  where
    redeemer = getRedeemer (scriptContextRedeemer ctx)

-- The entry point the ledger runs. A Plutus V3 script receives one
-- argument: the script context, with the datum and the redeemer inside.
lockUntyped :: BuiltinData -> Tx.BuiltinUnit
lockUntyped ctx = Tx.check (lockTyped (unsafeFromBuiltinData ctx))

-- Compile the validator to Plutus Core at compile time.
lockScript :: CompiledCode (BuiltinData -> Tx.BuiltinUnit)
lockScript = $$(compile [|| lockUntyped ||])

main :: IO ()
main = do
  writeCodeEnvelope "lock validator" lockScript "lock.plutus"
  putStrLn "wrote lock.plutus"
```

Read `lockTyped` first: it is the contract. When a transaction tries to spend
an output guarded by this script, the ledger runs the script with a
[`ScriptContext`]({% link explanation/structure.md %}) that describes the
whole transaction. The script looks up the **datum** (data stored with the
locked output; here, a secret number chosen at lock time) and the **redeemer**
(data supplied by the spending transaction; here, a guess). The rule: the
guess must equal the secret.

`lockUntyped` is the boundary with the ledger. A Plutus V3 script is a
function of **one** argument, the script context encoded as `BuiltinData`.
`unsafeFromBuiltinData` decodes it, and `Tx.check` turns the `Bool` into
"return unit or fail", which is how a validator reports its verdict.

**This contract is not secure.** The datum is stored on the chain in clear:
anyone can read the secret number and spend the funds. It is a teaching
device, not a lock. The "Where to go next" section points at a real
condition.
{:.warning}

## Step 2: Build the script file

```console
$ cabal update
$ cabal build
$ cabal run plinth-lock
```

This writes `lock.plutus`. The first tutorial produced readable UPLC text;
this program instead produces the JSON **text envelope** that Cardano tools
consume (see
[From Plinth to the chain]({% link explanation/from-plinth-to-the-chain.md %})):

```console
$ head -c 130 lock.plutus
{
    "type": "PlutusScriptV3",
    "description": "lock validator",
    "cborHex": "5905d20101009800aba4aba1ab9c4888c8c8c8c8c8c8c
```

`cborHex` is the on-chain script: the compiled UPLC, serialised with flat,
wrapped in a CBOR bytestring (`5905d2` is the CBOR header), and hex-encoded.
That one field is the entire on-chain artifact.

**Use a recent cardano-cli with this file.** Before 2025, envelopes carried
the script bytes wrapped in one extra CBOR layer. Since
[cardano-api #720](https://github.com/IntersectMBO/cardano-api/pull/720)
(January 2025) the script bytes are stored directly, as `writeCodeEnvelope`
does, and both forms are accepted when reading. `cardano-cli` versions older
than that change accept only the legacy form: from this file they silently
compute a **wrong script address** and fail to evaluate the script. The
devkit version this tutorial pins ships `cardano-cli` 11.0.0.0, which is
fine.
{:.warning}

## Step 3: Start a local Cardano network

Install Yaci DevKit (this tutorial was tested with version 0.12.0-beta5, the
current release at the time of writing):

```console
$ curl --proto '=https' --tlsv1.2 -LsSf https://devkit.yaci.xyz/install.sh | bash -s -- 0.12.0-beta5
```

It lands in `~/.yaci-devkit`. Start the containers; the command opens the
`yaci-cli` console when the containers are up:

```console
$ ~/.yaci-devkit/bin/devkit.sh start
```

At the `yaci-cli:>` prompt, create and start a devnet:

```
yaci-cli:> create-node -o --start
```

After a few seconds the node produces blocks. You have a private Cardano
network with instant funding and one-second blocks, running the same ledger
as mainnet. A block explorer is at
[http://localhost:5173](http://localhost:5173). Keep this terminal open: the
`devnet:default>` prompt is where you fund addresses in step 6.

## Step 4: A shell with cardano-cli

The devkit container has `cardano-cli` 11.0.0.0, already configured to talk
to the devnet node. In a **second terminal**, copy the script file into the
container and open a shell in it:

```console
$ docker cp lock.plutus node1-yaci-cli-1:/app/lock.plutus
$ ~/.yaci-devkit/bin/devkit.sh ssh
```

(`node1-yaci-cli-1` is the container name; if `docker cp` does not find it,
check the name with `docker ps`.)

The shell starts in `/app`, where you copied the file. All `cardano-cli`
commands below run in this shell. The devnet's network magic (its network
identifier) is **42**, a constant fixed by the devkit, so every command
carries `--testnet-magic 42`.

## Step 5: Keys and addresses

Create a payment key pair and its wallet address:

```console
$ cardano-cli address key-gen \
    --verification-key-file user.vkey \
    --signing-key-file user.skey
$ cardano-cli address build \
    --payment-verification-key-file user.vkey \
    --testnet-magic 42 --out-file user.addr
```

Then build the **script address** from `lock.plutus`:

```console
$ cardano-cli address build \
    --payment-script-file lock.plutus \
    --testnet-magic 42 --out-file script.addr
```

There is no key behind this address: it is the
[hash of the script]({% link explanation/from-plinth-to-the-chain.md %})
turned into an address. Funds sent there can only be spent by a transaction
that runs the script, and only if the script accepts.

Your wallet address is derived from your fresh key, so it is unique to you.
The script address is derived from the script bytes alone, so it is the same
for everyone who compiles this exact program with this exact compiler:

```console
$ cat script.addr
addr_test1wpwwelzpzfsgx034uqfq92msh4njfeywasm43xxsws978sqzs97m5
```

## Step 6: Fund your wallet

Back in the first terminal, at the `devnet:default>` prompt, send test ada to
your address (paste the content of `user.addr`):

```
devnet:default> topup <your address> 1000
```

In the cardano-cli shell, check that the funds arrived:

```console
$ cardano-cli conway query utxo --address $(cat user.addr) --testnet-magic 42
{
    "e67c838c9e784b3323efe3bf32a3e50abb6a7b27ae0d88ebe1064c7339a6c4e5#0": {
        "address": "addr_test1vp599v2pq78mcn59zttav2y3mk36qnh8gyfgld7gxd83jyg3p95wh",
        ...
        "value": {
            "lovelace": 1000000000
        }
    }
}
```

This is a UTxO: an unspent output your key controls, identified by
transaction hash and output index (the `TxHash#TxIx` key of the JSON
object). The amount is in lovelace, one millionth of an ada. Your hashes and
addresses will differ from the ones shown in this tutorial; use yours in the
commands below.

## Step 7: Lock funds at the script address

The first transaction sends 10 ada to the script address and stores the
secret number, 1234, as an **inline datum** with it:

```console
$ cardano-cli conway transaction build \
    --testnet-magic 42 \
    --tx-in <TxHash#TxIx from the query above> \
    --tx-out "$(cat script.addr)+10000000" \
    --tx-out-inline-datum-value 1234 \
    --change-address $(cat user.addr) \
    --out-file lock.txbody
$ cardano-cli conway transaction sign \
    --tx-body-file lock.txbody \
    --signing-key-file user.skey \
    --testnet-magic 42 --out-file lock.tx
$ cardano-cli conway transaction submit --tx-file lock.tx --testnet-magic 42
```

`build` takes `--tx-in` (the UTxO from step 6) as the money source, computes
the fee, and returns the rest to `--change-address`. `sign` witnesses it with
your key; `submit` sends it to the node. You should see:

```
Estimated transaction fee: 170561 Lovelace
Transaction successfully submitted. Transaction hash is:
{"txhash":"64814126a28fb98c85ebef262dbbd02660fad8e0554bad68f8ba018414e122a0"}
```

The funds are now at the script address, with the datum stored inline:

```console
$ cardano-cli conway query utxo --address $(cat script.addr) --testnet-magic 42
{
    "64814126a28fb98c85ebef262dbbd02660fad8e0554bad68f8ba018414e122a0#0": {
        "address": "addr_test1wpwwelzpzfsgx034uqfq92msh4njfeywasm43xxsws978sqzs97m5",
        "inlineDatum": {
            "int": 1234
        },
        ...
        "value": {
            "lovelace": 10000000
        }
    }
}
```

Your wallet also has a new UTxO: the change output, at index `1` of the same
transaction. You need both `TxHash#TxIx` values in the next step.

## Step 8: Unlock them

The second transaction spends the script output. This time the input is
guarded by a script, so the transaction carries the script itself, the
redeemer (the guess), and **collateral** &mdash; a plain UTxO from your wallet
that pays the fee only in the case where a script passes off-chain validation
but fails on the chain:

```console
$ cardano-cli conway transaction build \
    --testnet-magic 42 \
    --tx-in <TxHash#TxIx of the script output> \
    --tx-in-script-file lock.plutus \
    --tx-in-inline-datum-present \
    --tx-in-redeemer-value 1234 \
    --tx-in-collateral <TxHash#TxIx of a UTxO at your address> \
    --change-address $(cat user.addr) \
    --out-file unlock.txbody
$ cardano-cli conway transaction sign \
    --tx-body-file unlock.txbody \
    --signing-key-file user.skey \
    --testnet-magic 42 --out-file unlock.tx
$ cardano-cli conway transaction submit --tx-file unlock.tx --testnet-magic 42
```

To compute the fee, `build` runs your validator locally with the real datum,
redeemer, and transaction context &mdash; the same
[CEK evaluation]({% link explanation/plutus-core.md %}) the chain performs.
The guess is 1234, the secret is 1234, the script accepts, and the transaction
goes through (fee: 315005 lovelace; script fees are higher because the
transaction carries and runs the script). The 10 ada (minus the fee) is back
at your address:

```console
$ cardano-cli conway query utxo --address $(cat user.addr) --testnet-magic 42
{
    "64814126a28fb98c85ebef262dbbd02660fad8e0554bad68f8ba018414e122a0#1": {
        ...
        "value": {
            "lovelace": 989829439
        }
    },
    "a93ab90747aa42bb9c847c325eef14b8bc86aa160b6beccd9f854f89249e76ba#0": {
        ...
        "value": {
            "lovelace": 9684995
        }
    }
}
```

## Step 9: Try the wrong number

Lock 10 ada again (repeat step 7 with a fresh `--tx-in`), then build the
spending transaction with a wrong guess:

```console
$ cardano-cli conway transaction build \
    --testnet-magic 42 \
    --tx-in <TxHash#TxIx of the new script output> \
    --tx-in-script-file lock.plutus \
    --tx-in-inline-datum-present \
    --tx-in-redeemer-value 4321 \
    --tx-in-collateral <TxHash#TxIx of a UTxO at your address> \
    --change-address $(cat user.addr) \
    --out-file steal.txbody
```

The command fails before anything reaches the chain. `cardano-cli` prints
the script hash, the full decoded `ScriptContext` the validator saw (the
inputs, the inline datum `1234`, the redeemer `4321`, ...), and at the end:

```
Script evaluation error: An error has occurred:
The machine terminated because of an error, either from a built-in function or from an explicit use of 'error'.
Caused by: (error)
Script execution logs: wrong number
PT5
```

The `wrong number` message is the `traceIfFalse` string from `Main.hs`. This
is the point of the design: script evaluation is deterministic, so a
transaction that would fail on the chain fails identically on your machine,
and honest tools refuse to submit it. Collateral is only lost if someone
bypasses this check and submits a failing transaction anyway.

## Step 10: Shut it down

Exit the container shell, then stop the devkit (in the first terminal, `exit`
the yaci-cli console first if needed):

```console
$ ~/.yaci-devkit/bin/devkit.sh stop
```

The devnet state is kept between runs; `create-node -o` (the `-o` overwrites)
gives you a fresh chain next time.

## Where to go next

- [Lock and unlock funds from GHCi]({% link tutorials/lock-and-unlock-ghci.md %})
  &mdash; the same two transactions, built from Haskell with `cardano-api`
  instead of shell commands.
- Replace the secret number with a real condition: require a signature. The
  `ScriptContext` carries `txInfoSignatories`; check that a public key hash
  is in it, and pass `--required-signer-hash` to `transaction build`. See
  [The Plinth contract language]({% link explanation/plinth-language.md %}).
- [Generate a blueprint]({% link how-to/generate-blueprint.md %}) &mdash;
  publish the script's interface (CIP-57) so wallets and off-chain tools can
  use it.
- [Test a Plinth contract locally]({% link how-to/test.md %}) &mdash; the same
  validator logic can be unit-tested and budgeted without any network.
- [From Plinth to the chain]({% link explanation/from-plinth-to-the-chain.md %})
  &mdash; the concepts behind every artifact you produced here.

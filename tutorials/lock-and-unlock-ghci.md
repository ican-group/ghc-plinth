---
title: Lock and unlock funds from GHCi (Linux)
permalink: /tutorials/lock-and-unlock-ghci/
---
The [previous tutorial]({% link tutorials/lock-and-unlock.md %}) locked and
unlocked funds with `cardano-cli` commands. In this tutorial you do the same
from Haskell: a small library of helpers built on
[`cardano-api`](https://github.com/IntersectMBO/cardano-api), used
interactively from GHCi. At the end, the whole chain interaction looks like
this:

```
ghci> lockFunds 10_000_000 1234
ghci> unlockFunds 1234
```

A key point of this tutorial: the off-chain code is ordinary Haskell. It is a
separate project, built with a **standard GHC**, with no Plinth libraries in
it. The compiled validator crosses from one world to the other as the
`lock.plutus` file.

## Before you start

You need:

- the [previous tutorial]({% link tutorials/lock-and-unlock.md %}) completed:
  its `lock.plutus` file, and Yaci DevKit installed;
- GHC 9.6.7 and a recent `cabal` (`ghcup install ghc 9.6.7`; the tutorial
  project selects it by itself, it does not need to be your default GHC);
- [socat](http://www.dest-unreach.org/socat/), from your distribution's
  package manager (it connects GHCi to the devnet node);
- the LMDB and liburing libraries with their development files
  (`liblmdb-dev` and `liburing-dev` on Debian/Ubuntu, `lmdb` and `liburing`
  on most other distributions): the consensus layer that `cardano-api`
  pulls in links against them.

## Step 1: Create the project

Make a new directory and add the three files below.

**`cabal.project`** builds with a standard GHC and takes `cardano-api` from
the Cardano package repository (CHaP). The only source-repository blocks are
for the crypto libraries, built from source as in the other tutorials, so
nothing needs to be installed on your system:

```haskell
with-compiler: ghc-9.6.7

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

-- The Cardano crypto libraries, patched to build their C dependencies
-- from source (same approach as the on-chain project). The branch
-- carries cardano-crypto-class 2.3.3.0, the version this cardano-api
-- needs.
source-repository-package
  type: git
  location: https://github.com/ican-group/cardano-base
  tag: 205c260ed99566d2d2ae956622818a90817fadd9
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
  -- sodium-clib is the plain libsodium, without Cardano's VRF
  -- extension: tell cardano-crypto-praos to build its own VRF code.
  flags: +use-haskell-clibs -external-libsodium-vrf

package sodium-clib
  -- disable -fPIE: the static boot libraries are not built with it, so the
  -- link phase fails otherwise.
  configure-options: --enable-pie=no
```

**Not for production.** As in the other tutorials, the vendored crypto C
libraries built by the `*-clib` blocks have not been audited. Use this setup
for learning and experimentation only.
{:.warning}

**`lock-offchain.cabal`** describes a library, so that GHCi can load it:

```haskell
cabal-version: 3.0
name:          lock-offchain
version:       0.1.0.0
build-type:    Simple

library
  exposed-modules:  Offchain
  hs-source-dirs:   .
  default-language: GHC2021
  build-depends:
    , base
    , containers
    , directory
    , text
    , cardano-api
    , cardano-ledger-core
  ghc-options:
    -Wall
    -- cardano-api 11 deprecates this transaction-building API in
    -- favour of Cardano.Api.Experimental; it still is the stable one.
    -Wno-deprecations
```

**`Offchain.hs`** is the helper library, about 180 lines:

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

-- | Helpers to use the lock validator from GHCi against a local
-- devnet: query funds, lock them at the script address, unlock them
-- with a redeemer.
module Offchain where

import Cardano.Api
import Cardano.Api.Network qualified as Net
import Cardano.Ledger.Compactible (fromCompact)

import Data.Function ((&))
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import System.Directory (doesFileExist)

-- The devnet constants: Conway era, network magic 42.
sbe :: ShelleyBasedEra ConwayEra
sbe = ShelleyBasedEraConway

network :: NetworkId
network = Testnet (NetworkMagic 42)

-- | Connection to the devnet node through the local socket.
conn :: LocalNodeConnectInfo
conn =
  LocalNodeConnectInfo
    { localConsensusModeParams = CardanoModeParams (EpochSlots 21600)
    , localNodeNetworkId = network
    , localNodeSocketPath = File "node.sock"
    }

-- | Load the wallet key, generating and saving it on first use.
walletKey :: IO (SigningKey PaymentKey)
walletKey = do
  let path = "user.skey"
  exists <- doesFileExist path
  if exists
    then orDie =<< readFileTextEnvelope (File path)
    else do
      skey <- generateSigningKey AsPaymentKey
      _ <- orDie =<< writeFileTextEnvelope (File path) Nothing skey
      pure skey

-- | The wallet address (fund it with topup).
walletAddress :: IO (Address ShelleyAddr)
walletAddress = do
  skey <- walletKey
  let vkeyHash = verificationKeyHash (getVerificationKey skey)
  pure (makeShelleyAddress network (PaymentCredentialByKey vkeyHash) NoStakeAddress)

-- | The compiled validator, read from the envelope the on-chain
-- project wrote.
lockScript :: IO (PlutusScript PlutusScriptV3)
lockScript = orDie =<< readFileTextEnvelope (File "lock.plutus")

-- | The script address: the hash of the script, as an address.
scriptAddress :: IO (Address ShelleyAddr)
scriptAddress = do
  script <- lockScript
  let scriptHash = hashScript (PlutusScript PlutusScriptV3 script)
  pure (makeShelleyAddress network (PaymentCredentialByScript scriptHash) NoStakeAddress)

-- | An address in its text form (to paste in a topup command).
bech32 :: Address ShelleyAddr -> String
bech32 = Text.unpack . serialiseAddress

-- | The unspent outputs at an address, largest first.
utxosAt :: Address ShelleyAddr -> IO [(TxIn, TxOut CtxUTxO ConwayEra)]
utxosAt addr = do
  let query = queryUtxo sbe (QueryUTxOByAddress (Set.singleton (toAddressAny addr)))
  result <- executeLocalStateQueryExpr conn Net.VolatileTip query
  UTxO utxo <- orDie =<< orDie =<< orDie result
  pure
    $ sortOn (\(_, TxOut _ v _ _) -> Down (txOutValueToLovelace v))
    $ Map.toList utxo

-- | Print the unspent outputs at an address, one per line.
showUtxos :: Address ShelleyAddr -> IO ()
showUtxos addr = do
  utxos <- utxosAt addr
  mapM_ render utxos
  where
    render (TxIn txid (TxIx ix), TxOut _ value datum _) =
      putStrLn $
        Text.unpack (serialiseToRawBytesHexText txid)
          <> "#" <> show ix
          <> ": " <> show (unCoin (txOutValueToLovelace value)) <> " lovelace"
          <> case datum of
               TxOutDatumInline _ d -> ", datum " <> show (getScriptData d)
               _ -> ""

-- | Lock an amount at the script address, with the secret number
-- stored as the inline datum.
lockFunds :: Coin -> Integer -> IO TxId
lockFunds amount secret = do
  scriptAddr <- shelleyAddressInEra sbe <$> scriptAddress
  (walletIn, _) : _ <- utxosAt =<< walletAddress
  let datum = unsafeHashableScriptData (ScriptDataNumber secret)
      lockedOutput =
        TxOut
          scriptAddr
          (lovelaceToTxOutValue sbe amount)
          (TxOutDatumInline BabbageEraOnwardsConway datum)
          ReferenceScriptNone
  submit [walletIn] $
    defaultTxBodyContent sbe
      & setTxIns [(walletIn, BuildTxWith (KeyWitness KeyWitnessForSpending))]
      & setTxOuts [lockedOutput]

-- | Spend the output at the script address, giving a guess as the
-- redeemer. The transaction validates only if the guess equals the
-- stored secret.
unlockFunds :: Integer -> IO TxId
unlockFunds guess = do
  script <- lockScript
  (scriptIn, _) : _ <- utxosAt =<< scriptAddress
  (collateralIn, _) : _ <- utxosAt =<< walletAddress
  let redeemer = unsafeHashableScriptData (ScriptDataNumber guess)
      witness =
        PlutusScriptWitness
          PlutusScriptV3InConway
          PlutusScriptV3
          (PScript script)
          InlineScriptDatum
          redeemer
          (ExecutionUnits 0 0)
  submit [scriptIn, collateralIn] $
    defaultTxBodyContent sbe
      & setTxIns
          [(scriptIn, BuildTxWith (ScriptWitness ScriptWitnessForSpending witness))]
      & setTxInsCollateral (TxInsCollateral AlonzoEraOnwardsConway [collateralIn])

-- Note [Balancing a transaction]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- constructBalancedTx computes the fee, adds the change output, runs
-- the Plutus scripts to measure their budget, and signs. It needs the
-- current chain state (protocol parameters, the resolved inputs, the
-- start of time to convert slots): queryStateForBalancedTx fetches
-- all of it in one connection. One trap: constructBalancedTx does not
-- put the protocol parameters in the transaction body itself, and
-- without them the node rejects the transaction with
-- "ScriptIntegrityHashMismatch", so we set them explicitly.

-- | Balance, sign and submit a transaction; return its id.
submit :: [TxIn] -> TxBodyContent BuildTx ConwayEra -> IO TxId
submit inputs content = do
  skey <- walletKey
  changeAddr <- shelleyAddressInEra sbe <$> walletAddress
  queried <-
    executeLocalStateQueryExpr conn Net.VolatileTip $
      queryStateForBalancedTx (toCardanoEra sbe) inputs []
  (utxo, pparams, eraHistory, systemStart, stakePools, stakeDeposits, drepDeposits, _) <-
    orDie =<< orDie queried
  tx <-
    orDieBalance $
      constructBalancedTx
        sbe
        (content & setTxProtocolParams (BuildTxWith (Just pparams)))
        changeAddr
        Nothing
        utxo
        pparams
        (toLedgerEpochInfo eraHistory)
        systemStart
        stakePools
        stakeDeposits
        (Map.map fromCompact drepDeposits)
        [WitnessPaymentKey skey]
  submitTxToNodeLocal conn (TxInMode sbe tx) >>= \case
    TxSubmitSuccess -> pure (getTxId (getTxBody tx))
    failure -> fail (show failure)

orDie :: Show e => Either e a -> IO a
orDie = either (fail . show) pure

-- Render a validator rejection by its trace messages, not by the
-- full Show dump of the balancing error.
orDieBalance :: Either (TxBodyErrorAutoBalance ConwayEra) a -> IO a
orDieBalance = \case
  Right a -> pure a
  Left (TxBodyScriptExecutionError [(_, ScriptErrorEvaluationFailed failure)]) ->
    fail ("the validator rejected the transaction: "
          <> show (dpfExecutionLogs failure))
  Left err -> fail (show err)
```

Read it from the top:

- `conn` describes how to reach the node: a local socket, and the devnet's
  network magic 42.
- `walletKey` creates your payment key the first time it runs and stores it
  in `user.skey`; `walletAddress` is the address of that key.
- `lockScript` reads the compiled validator from `lock.plutus` &mdash; the
  file is the only thing this project shares with the on-chain one &mdash;
  and `scriptAddress` turns its hash into the script address, the same
  operation `cardano-cli address build` performed in the previous tutorial.
- `utxosAt` and `showUtxos` query the node for the unspent outputs at an
  address.
- `lockFunds` builds the lock transaction: one input from your wallet, one
  output at the script address with the secret number as its inline datum.
- `unlockFunds` builds the spending transaction: the script output as input,
  witnessed by the script itself with your guess as the redeemer, plus a
  collateral input from your wallet. The execution units are left at zero:
  balancing measures the real cost by running the validator.
- `submit` does the plumbing all transactions share. It queries the chain
  state, then `constructBalancedTx` computes the fee, adds the change output,
  runs the Plutus scripts to measure their budget, and signs; see
  Note [Balancing a transaction] for the one trap.

`cardano-api` 11 marks this transaction-building API as deprecated in favour
of its experimental successor; it is still the stable interface, and the one
`cardano-cli` itself uses. The cabal file silences the warnings. The
[next tutorial]({% link tutorials/lock-and-unlock-ghci-exp.md %}) rebuilds
these helpers on the experimental interface.
{:.note}

## Step 2: Build it

```console
$ cabal update
$ cabal build
```

The first build compiles `cardano-api` and the Cardano ledger, so expect it
to take a while.

## Step 3: Start the devnet

As in the previous tutorial:

```console
$ ~/.yaci-devkit/bin/devkit.sh start
```

```
yaci-cli:> create-node -o --start
```

Keep this terminal open for the `topup` command later.

## Step 4: Connect the project to the node

In a second terminal, in the project directory, copy in the compiled
validator from the previous tutorial's project directory:

```console
$ cp <path to the previous project>/lock.plutus .
```

`cardano-api` talks to a node through a Unix socket. The node runs inside
the devkit container, which exposes its socket as TCP port 3333; one `socat`
process turns that back into a local socket file:

```console
$ socat UNIX-LISTEN:node.sock,fork,reuseaddr TCP:127.0.0.1:3333 &
```

## Step 5: Lock and unlock, from GHCi

Start GHCi with the library loaded:

```console
$ cabal repl
ghci> putStrLn . bech32 =<< walletAddress
addr_test1vqtrkpagy3affqvz8eny4d8vuhhywdz5yn8gpjt2n8xrw9g52mc72
ghci> putStrLn . bech32 =<< scriptAddress
addr_test1wpwwelzpzfsgx034uqfq92msh4njfeywasm43xxsws978sqzs97m5
```

The first call created `user.skey` and shows your wallet address; yours will
differ. The script address is computed from `lock.plutus` and is **the same
address** the previous tutorial computed with `cardano-cli`.

Fund the wallet: paste your wallet address in a `topup` at the
`devnet:default>` prompt of the first terminal, then look at it from GHCi:

```
devnet:default> topup addr_test1vqtrkpagy3affqvz8eny4d8vuhhywdz5yn8gpjt2n8xrw9g52mc72 1000
```

```
ghci> showUtxos =<< walletAddress
84fa0e8bf3ae85760e8cffcbb39161d6cb8fad8053564722aa53c618a17bb8cc#0: 1000000000 lovelace
```

Lock 10 ada with the secret number 1234, and watch it arrive at the script
address (the returned value is the transaction id; give the devnet a couple
of seconds to include each transaction in a block):

```
ghci> lockFunds 10_000_000 1234
"704a1dd13b3dc75c7063cb18e9417f6e7d46e4f801a50f79c7814ff9bd2bdc35"
ghci> showUtxos =<< scriptAddress
704a1dd13b3dc75c7063cb18e9417f6e7d46e4f801a50f79c7814ff9bd2bdc35#0: 10000000 lovelace, datum ScriptDataNumber 1234
```

Unlock it with the right guess:

```
ghci> unlockFunds 1234
"3cf801679887ac6c9457d93124669d773156968b739abb400a24d85d37bd3bf6"
ghci> showUtxos =<< walletAddress
704a1dd13b3dc75c7063cb18e9417f6e7d46e4f801a50f79c7814ff9bd2bdc35#1: 989829439 lovelace
3cf801679887ac6c9457d93124669d773156968b739abb400a24d85d37bd3bf6#0: 9684995 lovelace
```

The 10 ada is back (minus the fee), next to the change of the lock
transaction. Now lock once more and try to steal it with a wrong guess:

```
ghci> lockFunds 10_000_000 1234
"5f7c8f066b3c042dcf037c811d778ec33825c871cf9fde8fc7c5de9a759244d9"
ghci> unlockFunds 4321
*** Exception: user error (the validator rejected the transaction: ["wrong number","PT5"])
```

As with `cardano-cli`, the transaction fails before it reaches the chain:
balancing runs the validator, the validator says no, and the `traceIfFalse`
message from the Plinth code surfaces in your GHCi session.

## Step 6: Shut it down

Exit GHCi, stop the socket bridge, and stop the devkit:

```console
$ kill %1
$ ~/.yaci-devkit/bin/devkit.sh stop
```

## Where to go next

- [Lock and unlock funds with the experimental cardano-api]({% link tutorials/lock-and-unlock-ghci-exp.md %})
  &mdash; the same helpers, rebuilt on the successor of this tutorial's
  deprecated transaction-building interface.
- Extend `Offchain.hs`: a `stealFunds` that spends with someone else's key, a
  parameter for the locked amount's address, a loop that watches the script
  address.
- [Test a Plinth contract locally]({% link how-to/test.md %}) &mdash; the
  same validator logic, exercised without any network.
- [The structure of a Plinth smart contract]({% link explanation/structure.md %})
  &mdash; where this off-chain code sits in a real project.

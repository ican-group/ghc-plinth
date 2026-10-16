---
title: Lock and unlock funds with the experimental cardano-api (Linux)
permalink: /tutorials/lock-and-unlock-ghci-exp/
---
The [GHCi tutorial]({% link tutorials/lock-and-unlock-ghci.md %}) used the
transaction-building interface that `cardano-api` 11 marks as deprecated. In
this tutorial you build the same helpers on its designated successor,
`Cardano.Api.Experimental`. The GHCi session at the end is identical; the
engine underneath is the new one.

**The experimental interface changes.** It is the announced direction of
`cardano-api`, but it does not promise stability yet. This tutorial pins the
package versions it was tested with; expect adjustments when you move to a
newer `cardano-api`.
{:.warning}

## What changes, in one look

The new interface stays much closer to the ledger:

- The transaction body content uses **ledger types directly**: a ledger
  address, a ledger value, a ledger datum, and it is indexed by the ledger
  era, not the API era.
- Witnesses are part of the input list as plain values
  (`AnyKeyWitnessPlaceholder`, or a Plutus script witness), with no
  `BuildTxWith` wrappers.
- There is no all-in-one balancing function. Building a transaction is an
  explicit pipeline: shape it, measure the scripts, rebalance, sign. Each
  step is a separate function, and you see exactly what happens.

## Before you start

Everything from the
[GHCi tutorial]({% link tutorials/lock-and-unlock-ghci.md %}): its
`lock.plutus` file, Yaci DevKit, GHC 9.6.7, `socat`.

## Step 1: Create the project

Make a new directory and add the three files below.

**`cabal.project`** is identical to the previous tutorial's:

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

**`lock-offchain-exp.cabal`** adds two ledger packages: the new interface
works with ledger types, so the project uses a few of them directly:

```haskell
cabal-version: 3.0
name:          lock-offchain-exp
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
    , cardano-ledger-babbage
  ghc-options:
    -Wall
    -- cardano-api 11 deprecates this transaction-building API in
    -- favour of Cardano.Api.Experimental; it still is the stable one.
    -Wno-deprecations
```

**`Offchain.hs`** exposes the same functions as before (`walletAddress`,
`scriptAddress`, `showUtxos`, `lockFunds`, `unlockFunds`); only their
internals changed:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

-- | Helpers to use the lock validator from GHCi against a local
-- devnet, built on the experimental cardano-api interface
-- (Cardano.Api.Experimental).
module Offchain where

import Cardano.Api
import Cardano.Api.Experimental qualified as Exp
import Cardano.Api.Experimental.AnyScriptWitness
  (AnyPlutusScriptWitness (AnyPlutusSpendingScriptWitness),
   PlutusSpendingScriptWitness (PlutusSpendingScriptWitnessV3))
import Cardano.Api.Experimental.Plutus qualified as EP
import Cardano.Api.Experimental.Tx qualified as Exp
import Cardano.Api.Ledger qualified as L
import Cardano.Api.Network qualified as Net
import Cardano.Ledger.Babbage.TxBody qualified as L
import Cardano.Ledger.Plutus.Data qualified as L
import Cardano.Ledger.Plutus.Language qualified as Plutus

import Data.Function ((&))
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import System.Directory (doesFileExist)

-- The devnet constants: Conway era, network magic 42. The
-- experimental interface has its own era witness type.
era :: Exp.Era Exp.ConwayEra
era = Exp.ConwayEra

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
-- project wrote, as the experimental script type.
lockScript :: IO (EP.PlutusScriptInEra Plutus.PlutusV3 (Exp.LedgerEra Exp.ConwayEra))
lockScript = do
  envelope <- orDie =<< readTextEnvelopeFromFile "lock.plutus"
  orDie (EP.deserialisePlutusScriptInEra Plutus.SPlutusV3 (textEnvelopeRawCBOR envelope))

-- | The script address: the hash of the script, as an address.
scriptAddress :: IO (Address ShelleyAddr)
scriptAddress = do
  script <- lockScript
  let scriptHash = fromShelleyScriptHash (EP.hashPlutusScriptInEra script)
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

-- The transaction body type of the experimental interface uses ledger
-- types directly: a ledger address, a ledger value, a ledger datum.
type LedgerConway = Exp.LedgerEra Exp.ConwayEra

ledgerAddress :: Address ShelleyAddr -> L.Addr
ledgerAddress addr = toShelleyAddr (shelleyAddressInEra sbe addr)

ledgerDatum :: HashableScriptData -> L.Datum LedgerConway
ledgerDatum d = L.Datum (L.dataToBinaryData (L.Data (toPlutusData (getScriptData d))))

-- | Lock an amount at the script address, with the secret number
-- stored as the inline datum.
lockFunds :: Coin -> Integer -> IO TxId
lockFunds amount secret = do
  scriptAddr <- scriptAddress
  (walletIn, _) : _ <- utxosAt =<< walletAddress
  let datum = unsafeHashableScriptData (ScriptDataNumber secret)
      lockedOutput =
        Exp.TxOut $
          L.BabbageTxOut
            (ledgerAddress scriptAddr)
            (L.MaryValue amount mempty)
            (ledgerDatum datum)
            L.SNothing
  submit [walletIn] $
    Exp.defaultTxBodyContent
      & Exp.setTxIns [(walletIn, Exp.AnyKeyWitnessPlaceholder)]
      & Exp.setTxOuts [lockedOutput]

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
        Exp.AnyPlutusScriptWitness $
          AnyPlutusSpendingScriptWitness $
            PlutusSpendingScriptWitnessV3 $
              Exp.PlutusScriptWitness
                Plutus.SPlutusV3
                (EP.PScript script)
                Exp.InlineDatum
                redeemer
                (ExecutionUnits 0 0)
  submit [scriptIn, collateralIn] $
    Exp.defaultTxBodyContent
      & Exp.setTxIns [(scriptIn, witness)]
      & Exp.setTxInsCollateral [collateralIn]

-- Note [Balancing with the experimental interface]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- There is no single balancing function. The steps are explicit:
--
-- 1. makeUnsignedTx turns the body content into a transaction. The
--    protocol parameters must be in the content (the script integrity
--    hash is computed from them).
-- 2. calcMinFeeRecursive computes the fee and appends the change
--    output. We run it once on a draft with zero execution units,
--    only to give the transaction its final shape.
-- 3. evaluateTransaction runs the Plutus scripts against the current
--    chain state and measures their execution units. It takes a
--    signed transaction, so we sign the draft. Measuring on the
--    SHAPED transaction matters: the validator receives the whole
--    transaction as its ScriptContext, so a change output appended
--    after the measurement would make the real cost higher than the
--    measured one, and the chain would reject the transaction.
-- 4. substituteExecutionUnits writes the measured units into the
--    content; makeUnsignedTx and calcMinFeeRecursive rebuild and
--    rebalance with them.
-- 5. Sign and submit. The experimental transaction converts to the
--    submission type with the ShelleyTx constructor.

-- | Balance, sign and submit a transaction; return its id.
submit :: [TxIn] -> Exp.TxBodyContent LedgerConway -> IO TxId
submit inputs content = do
  skey <- walletKey
  changeAddr <- walletAddress
  queried <-
    executeLocalStateQueryExpr conn Net.VolatileTip $
      queryStateForBalancedTx (toCardanoEra sbe) inputs []
  (utxo, lpp, eraHistory, systemStart, _, _, _, _) <-
    orDie =<< orDie queried
  let pparams = unLedgerProtocolParameters lpp
      ledgerUtxo = toLedgerUTxO sbe utxo
      contentWithParams = content & Exp.setTxProtocolParams pparams
      balance unsigned =
        Exp.calcMinFeeRecursive
          (ledgerAddress changeAddr)
          unsigned
          ledgerUtxo
          pparams
          mempty
          mempty
          mempty
          0

  -- Balance a zero-units draft to give the transaction its final
  -- shape, then sign it and run the scripts to measure their budget.
  draft <- orDie . balance =<< orDie (Exp.makeUnsignedTx era contentWithParams)
  let evaluation =
        Exp.evaluateTransaction
          systemStart
          (toLedgerEpochInfo eraHistory)
          pparams
          mempty
          mempty
          mempty
          ledgerUtxo
          (signedLedgerTx skey draft)
  exUnits <- traverse budgetOrDie (Exp.txEvalExecutionUnits evaluation)

  -- Rebuild with the measured budget, rebalance, sign.
  measured <- orDie (Exp.substituteExecutionUnits exUnits contentWithParams)
  balanced <- orDie . balance =<< orDie (Exp.makeUnsignedTx era measured)
  let tx = ShelleyTx sbe (signedLedgerTx skey balanced)
  submitTxToNodeLocal conn (TxInMode sbe tx) >>= \case
    TxSubmitSuccess -> pure (getTxId (getTxBody tx))
    failure -> fail (show failure)

-- | Sign with the wallet key, as a ledger-level transaction.
signedLedgerTx
  :: SigningKey PaymentKey
  -> Exp.UnsignedTx LedgerConway
  -> L.Tx L.TopTx LedgerConway
signedLedgerTx skey unsigned =
  let wit = Exp.makeKeyWitness era unsigned (WitnessPaymentKey skey)
      Exp.SignedTx tx = Exp.signTx era [] [wit] unsigned
   in tx

orDie :: Show e => Either e a -> IO a
orDie = either (fail . show) pure

-- Render a validator rejection by its trace messages, not by the
-- full Show dump of the evaluation error.
budgetOrDie
  :: Either ScriptExecutionError ([Text.Text], ExecutionUnits)
  -> IO ExecutionUnits
budgetOrDie = \case
  Right (_, units) -> pure units
  Left (ScriptErrorEvaluationFailed failure) ->
    fail ("the validator rejected the transaction: "
          <> show (dpfExecutionLogs failure))
  Left err -> fail (show err)
```

Read it against the previous tutorial's version:

- `era` is the experimental era witness (`Exp.Era Exp.ConwayEra`); the old
  `sbe` remains for the parts that did not change: queries, key handling,
  submission.
- `lockScript` now produces the experimental script type,
  `PlutusScriptInEra PlutusV3`, deserialised from the envelope's bytes, and
  `scriptAddress` hashes it with `hashPlutusScriptInEra`.
- `lockFunds` builds the locked output as a **ledger** `BabbageTxOut`: a
  ledger address, a `MaryValue`, and the datum converted down to the
  ledger's binary form (`ledgerDatum`). The wallet input carries
  `AnyKeyWitnessPlaceholder` instead of a `BuildTxWith` key witness.
- `unlockFunds` wraps the script witness in the new types: language
  singleton `SPlutusV3`, the script, `InlineDatum`, the redeemer, and zero
  execution units to start from.
- `submit` is where the real difference lives: the explicit balancing
  pipeline. See Note [Balancing with the experimental interface] in the
  code. One step deserves attention: the scripts are measured on a
  transaction that already has its **final shape** (change output included).
  The validator receives the whole transaction as its `ScriptContext`, so
  measuring before the change output exists underestimates the budget, and
  the chain rejects the transaction. The classic
  `constructBalancedTx` did this dance for you; here it is visible.

## Step 2: Build it

```console
$ cabal update
$ cabal build
```

Most dependencies are shared with the previous tutorial, so this build is
fast if you kept its store.

## Step 3: Start the devnet and connect

Exactly as in the previous tutorial: start the devkit and create a devnet in
one terminal; in a second terminal, in the project directory:

```console
$ cp <path to the lock project>/lock.plutus .
$ socat UNIX-LISTEN:node.sock,fork,reuseaddr TCP:127.0.0.1:3333 &
```

## Step 4: The same session

```console
$ cabal repl
ghci> putStrLn . bech32 =<< walletAddress
addr_test1vzxr2n07uvqx02ekrqtnlv6jsxedjre4n96qfc5n32lja7spn034t
```

Fund it (`topup <your address> 1000` at the `devnet:default>` prompt), then:

```
ghci> showUtxos =<< walletAddress
c4d016fef0c3794b0aa7e2cf798c9d0abdae7527ee430d1ba128532480a8b6a3#0: 1000000000 lovelace
ghci> lockFunds 10_000_000 1234
"78bf4b6e3c0dbc4de51031178ddaab328ff5624f754fdf2e07f3288fc15c4f63"
ghci> showUtxos =<< scriptAddress
78bf4b6e3c0dbc4de51031178ddaab328ff5624f754fdf2e07f3288fc15c4f63#0: 10000000 lovelace, datum ScriptDataNumber 1234
ghci> unlockFunds 1234
"4901bd37c2ff805a5ea4bafd5ff52c2ca297e662b7a9d941871378fa0c96a409"
ghci> showUtxos =<< walletAddress
78bf4b6e3c0dbc4de51031178ddaab328ff5624f754fdf2e07f3288fc15c4f63#1: 989833883 lovelace
4901bd37c2ff805a5ea4bafd5ff52c2ca297e662b7a9d941871378fa0c96a409#0: 9691551 lovelace
ghci> lockFunds 10_000_000 1234
"435390cdef1fd4403882f1d5f1a14dfc5a69c96e7776d09610866c019d56d0e2"
ghci> unlockFunds 4321
*** Exception: user error (the validator rejected the transaction: ["wrong number","PT5"])
```

Same behaviour as before, from the `topup` to the `wrong number` trace. The
script address is the same as ever; the fees differ by a few thousand
lovelace because the two balancers do not produce byte-identical
transactions.

Shut everything down as in the previous tutorial (`kill %1`, then
`devkit.sh stop`).

## Where to go next

- Compare `submit` in the two `Offchain.hs` files side by side: it is a
  compact map from the classic interface to the experimental one.
- [The structure of a Plinth smart contract]({% link explanation/structure.md %})
  &mdash; where off-chain code sits in a real project.
- The [`cardano-api` repository](https://github.com/IntersectMBO/cardano-api)
  &mdash; the experimental interface evolves there; its module documentation
  and test suite (`Test.Cardano.Api.Experimental`) are the reference.

---
title: Run an auction on a local chain (Linux)
permalink: /tutorials/auction/
---
In the [lock tutorials]({% link tutorials/lock-and-unlock-ghci.md %}), one
transaction locked funds and one transaction unlocked them. Most contracts do
more: they have a **state** that changes many times. In this tutorial you
build an auction. A seller offers an item, Alice and Bob bid, and after the
end time the highest bidder gets the item and the seller gets the money.

You learn:

- how a contract keeps its state from one transaction to the next;
- how the previous bidder gets their money back, and how their wallet finds
  it;
- why the address of the auction does not change when the bids change;
- why you must identify the real auction output, and how.

This tutorial targets **Linux**.

## How the auction works

A transaction cannot change an output. It can only spend outputs and create
new ones. So the auction keeps its state in the **datum** of one output at
the script address: the **auction output**. Each step of the auction spends
the auction output and creates a new one, with the new state in its datum.
The new output is the **continuing output**. The validator checks it: it must
go back to the same script address, with the correct datum and value.

The auction keeps its data in three places:

- the **parameters** of the validator: the seller, the item, the minimum bid
  and the end time. The seller chooses them when the auction starts, and they
  become part of the script;
- the **datum** of the auction output: the highest bid so far and the key of
  the bidder, or "no bid" at the start;
- the **value** of the auction output: the item, and the ada of the highest
  bid. The contract holds this ada until the end of the auction.

This diagram shows the whole auction that you run in this tutorial:

![An auction as a chain of outputs at one script address: each bid transaction spends the current auction output, creates the next one with the new highest bid in its datum, and refunds the previous owner of the ada.]({{ '/assets/images/auction-state.svg' | relative_url }})

Read it from left to right:

1. **Start.** The seller mints the item (a token) and locks it at the script
   address, with "no bid" in the datum. Every output must hold some ada, so
   the seller adds a deposit of 2 ada.
2. **Alice bids 100 ada.** Her transaction spends auction output 1 and creates
   auction output 2, which holds the item and her 100 ada. The transaction also
   gives the ada of auction output 1 (the deposit) back to its owner, the
   seller.
3. **Bob bids 150 ada.** His transaction spends auction output 2 and creates
   auction output 3. It gives Alice's 100 ada back to Alice.
4. **Payout.** After the end time, a transaction spends auction output 3. It
   gives the item to Bob and the 150 ada to the seller. The seller also adds
   2 ada to the output that carries the item (not shown).

At any time, only the newest auction output is unspent. The chain does not keep
a list of bids: the history of the auction is the chain of spent auction
outputs.

Some properties follow from this design:

- **The address does not change.** A script address is the hash of the
  script. The parameters are part of the script, but the datum and the value
  are not: they are in the output, next to the address. So all the auction
  outputs of one auction are at the same address. An auction with other
  parameters has a different script, so a different address.
- **A refund needs no notification.** A refund is a usual output to the
  address of the previous bidder. A wallet finds its money by asking the
  chain for the outputs at its addresses. So the previous bidder's wallet
  shows the refund the next time that it asks. Only the key of that address
  can spend it.
- **Only one bid per state.** All the bids spend the same auction output. If
  two bidders build on the same state, only the first transaction in a block
  is valid. The node rejects the second one because its input is already
  spent, and the bidder pays no fee. The second bidder must bid again, on the
  new state.
- **The item identifies the auction output.** Anyone can send an output with
  any datum to the script address, for example with a false "highest bid".
  So the validator requires the item in each continuing output, and bidders
  use the output that holds the item. A real contract also makes sure that
  only one such token can exist: see [Where to go next](#where-to-go-next).

## Before you start

You need:

- the [GHCi lock tutorial]({% link tutorials/lock-and-unlock-ghci.md %})
  completed: Yaci DevKit, socat, GHC 9.6.7 and the system libraries of
  `cardano-api`;
- `uplc-ghc` 9.6.169.3, installed as in
  [the first tutorial]({% link tutorials/first-smart-contract.md %}).

You make two projects, as in the lock tutorials:

- `auction`: the validator, in Plinth, built with `uplc-ghc`. It writes
  `auction.plutus`;
- `auction-ghci`: the off-chain helpers, in Haskell, built with a standard
  GHC. You use them from GHCi to run the auction.

## Step 1: The validator

Make a directory `auction` with three files.

**`cabal.project`** is the same as in the
[lock tutorial]({% link tutorials/lock-and-unlock.md %}):

```haskell
-- The uplc-ghc release. The ghc-plinth-plutus tag below must be the commit
-- that this release is built from.
with-compiler: uplc-ghc-9.6.169.2
with-hc-pkg:   uplc-ghc-pkg-9.6.169.2

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

**`plinth-auction.cabal`** is the lock tutorial's file, with the new name:

```haskell
cabal-version: 3.0
name:          plinth-auction
version:       0.1.0.0
build-type:    Simple

executable plinth-auction
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

**`Main.hs`** has the validator:

```haskell
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

module Main where

import PlutusTx
import qualified PlutusTx.Prelude as Tx
import qualified PlutusTx.List as List
import PlutusLedgerApi.V3
  ( CurrencySymbol, Datum (..), OutputDatum (..), POSIXTime, PubKeyHash
  , ScriptContext (..), ScriptInfo (..), TokenName, TxInInfo (..)
  , TxInfo (..), TxOut (..), getLovelace, getRedeemer )
import PlutusLedgerApi.V1.Address (toPubKeyHash)
import PlutusLedgerApi.V1.Interval (contains, from, to)
import PlutusLedgerApi.V1.Value (lovelaceValueOf, valueOf)
import PlutusLedgerApi.Envelope (writeCodeEnvelope)

-- The terms of one auction. The seller chooses them when the auction
-- starts. They are applied to the script, so they are part of its hash:
-- each auction has its own script address.
data AuctionParams = AuctionParams
  { seller     :: PubKeyHash      -- gets the highest bid
  , itemPolicy :: CurrencySymbol  -- the item for sale is one token
  , itemName   :: TokenName       -- of this policy and name
  , minBid     :: Integer         -- in lovelace
  , endTime    :: POSIXTime       -- the last time to bid
  }
makeIsDataIndexed ''AuctionParams [('AuctionParams, 0)]

-- A bid: who made it, and how much (in lovelace).
data Bid = Bid
  { bidder :: PubKeyHash
  , amount :: Integer
  }
makeIsDataIndexed ''Bid [('Bid, 0)]

-- The datum of the auction output, that is the state of the auction: the
-- highest bid so far, or Nothing before the first bid.
type AuctionDatum = Maybe Bid

-- What the spending transaction wants to do.
data AuctionRedeemer = NewBid Bid | Payout
makeIsDataIndexed ''AuctionRedeemer [('NewBid, 0), ('Payout, 1)]

-- The on-chain rules. The transaction spends the auction output, whose
-- datum holds the highest bid so far.
auctionTyped :: AuctionParams -> ScriptContext -> Bool
auctionTyped params ctx =
  case scriptContextScriptInfo ctx of
    SpendingScript ownRef (Just (Datum datum)) ->
      let highest = unsafeFromBuiltinData datum :: AuctionDatum
          -- The output that this transaction spends: the current state.
          ownOutput = case List.find (\i -> txInInfoOutRef i Tx.== ownRef) inputs of
            Just i -> txInInfoResolved i
            Nothing -> Tx.traceError "own input not found"
      in case unsafeFromBuiltinData (getRedeemer (scriptContextRedeemer ctx)) of
           NewBid bid -> checkBid ownOutput highest bid
           Payout -> checkPayout highest
    _ -> Tx.traceError "expected a spending script with a datum"
  where
    info = scriptContextTxInfo ctx
    inputs = txInfoInputs info
    outputs = txInfoOutputs info

    lovelaceIn :: TxOut -> Integer
    lovelaceIn o = getLovelace (lovelaceValueOf (txOutValue o))

    hasItem :: TxOut -> Bool
    hasItem o = valueOf (txOutValue o) (itemPolicy params) (itemName params) Tx.== 1

    -- Some output pays to this key and satisfies the condition.
    paysTo :: PubKeyHash -> (TxOut -> Bool) -> Bool
    paysTo pkh ok =
      List.any (\o -> toPubKeyHash (txOutAddress o) Tx.== Just pkh Tx.&& ok o) outputs

    -- A new bid. The transaction must:
    checkBid :: TxOut -> AuctionDatum -> Bid -> Bool
    checkBid ownOutput highest bid =
      -- 1. offer more than the highest bid (the first bid: at least
      --    the minimum bid),
      Tx.traceIfFalse "bid too low"
        (case highest of
           Nothing -> amount bid Tx.>= minBid params
           Just prev -> amount bid Tx.> amount prev)
      -- 2. be valid only up to the end time,
      Tx.&& Tx.traceIfFalse "too late to bid"
        (to (endTime params) `contains` txInfoValidRange info)
      -- 3. give the ada of the current auction output back to its owner:
      --    the previous bidder, or the seller before the first bid,
      Tx.&& Tx.traceIfFalse "no refund to the previous bidder"
        (paysTo previousOwner (\o -> lovelaceIn o Tx.>= lovelaceIn ownOutput))
      -- 4. create exactly one new auction output, at the same address,
      --    with the new bid as its datum, and the item and the new bid
      --    as its value.
      Tx.&& Tx.traceIfFalse "wrong new auction output"
        (case List.filter (\o -> txOutAddress o Tx.== txOutAddress ownOutput) outputs of
           [o] ->
             txOutDatum o Tx.== OutputDatum (Datum (toBuiltinData (Just bid)))
               Tx.&& hasItem o
               Tx.&& lovelaceIn o Tx.== amount bid
           _ -> False)
      where
        previousOwner = case highest of
          Nothing -> seller params
          Just prev -> bidder prev

    -- The payout, after the end time. The transaction must give the item
    -- to the highest bidder and the highest bid to the seller (or the item
    -- back to the seller if nobody did bid).
    checkPayout :: AuctionDatum -> Bool
    checkPayout highest =
      Tx.traceIfFalse "too early to pay out"
        (from (endTime params) `contains` txInfoValidRange info)
      Tx.&& case highest of
        Nothing ->
          Tx.traceIfFalse "the item does not go back to the seller"
            (paysTo (seller params) hasItem)
        Just bid ->
          Tx.traceIfFalse "the item does not go to the highest bidder"
            (paysTo (bidder bid) hasItem)
          Tx.&& Tx.traceIfFalse "the seller does not get the highest bid"
            (paysTo (seller params) (\o -> lovelaceIn o Tx.>= amount bid))

-- The entry point. It takes the parameters first, then the script
-- context: the off-chain code applies the parameters to get the script
-- of one auction.
auctionUntyped :: BuiltinData -> BuiltinData -> Tx.BuiltinUnit
auctionUntyped params ctx =
  Tx.check (auctionTyped (unsafeFromBuiltinData params) (unsafeFromBuiltinData ctx))

auctionScript :: CompiledCode (BuiltinData -> BuiltinData -> Tx.BuiltinUnit)
auctionScript = $$(compile [|| auctionUntyped ||])

main :: IO ()
main = do
  writeCodeEnvelope "auction validator, without its parameters" auctionScript "auction.plutus"
  putStrLn "wrote auction.plutus"
```

Read the types first:

- `AuctionParams` are the parameters. `itemPolicy` and `itemName` identify the
  item: one token of that policy and name.
- `Bid` is a bid: the key hash of the bidder, and the amount in lovelace (one
  ada is 1,000,000 lovelace).
- `AuctionDatum` is the state: `Nothing` before the first bid, then the
  highest bid.
- `AuctionRedeemer` tells the validator what the transaction does: a new bid,
  or the payout.

`makeIsDataIndexed` gives each type its encoding as `Data`, the format of
datums and redeemers: a constructor with index *i* and fields *x* and *y* is
`Constr i [x, y]`. The off-chain code must build exactly these values (see
step 3).

Then read `checkBid`. It has the four rules of a bid, numbered in the
comments. Compare them with the diagram:

1. the bid must be higher than the highest bid (or at least the minimum bid);
2. the transaction must not be valid after the end time;
3. the ada of the spent auction output goes back to its owner: the previous
   bidder, or the seller (the deposit) before the first bid;
4. there is exactly one new auction output at the same address. Its datum is
   the new bid, and its value is the item and the new bid.

`checkPayout` has the rules of the payout: not before the end time, the item
to the highest bidder, the highest bid to the seller.

`txInfoValidRange` is the **validity interval** of the transaction: the time
interval in which the ledger accepts it. A script cannot read the current
time, because then the result would depend on the moment of validation. So
the transaction states its own interval, and the ledger checks it. Rule 2
says: the interval must end before the end time. The payout must start after
it.

Last, the entry point. `auctionUntyped` takes **two** arguments: the
parameters, then the script context. The ledger gives a script only one
argument, the script context. The off-chain code applies the parameters
first (see step 3), and the result is the script of one auction.

## Step 2: Build auction.plutus

```console
$ cabal update
$ cabal build
$ cabal run plinth-auction
wrote auction.plutus
```

`auction.plutus` holds the validator **without** its parameters. You cannot
use it at the chain directly: there is no address for it yet.

## Step 3: The off-chain helpers

Make a directory `auction-ghci` with four files.

**`cabal.project`** is the same as in the
[GHCi lock tutorial]({% link tutorials/lock-and-unlock-ghci.md %}):

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
  location: https://github.com/hsyl20/cardano-base
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

**`auction-offchain.cabal`** adds `plutus-core` and `plutus-ledger-api` to the
dependencies of the lock project. `cardano-api` already depends on them; the
helpers use them to apply the parameters to the validator:

```haskell
cabal-version: 3.0
name:          auction-offchain
version:       0.1.0.0
build-type:    Simple

library
  exposed-modules:  Offchain
  other-modules:    Chain
  hs-source-dirs:   .
  default-language: GHC2021
  build-depends:
    , base
    , bytestring
    , containers
    , directory
    , text
    , time
    , cardano-api
    , cardano-ledger-core
    , plutus-core
    , plutus-ledger-api
  ghc-options:
    -Wall
    -- cardano-api 11 deprecates this transaction-building API in
    -- favour of Cardano.Api.Experimental; it still is the stable one.
    -Wno-deprecations
```

**`Chain.hs`** has the plumbing. It is not specific to the auction, and you
know most of it from the lock tutorial: the connection to the devnet, the
wallet keys (one file `<name>.skey` for each wallet, made on first use), the
queries, and `submitAndWait`, which balances, signs and submits a transaction
and waits until it is in a block. You can copy it without reading it:

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

-- | The plumbing of the auction helpers, as in the lock tutorial: the
-- connection to the devnet, wallet keys, chain queries, and the
-- submission of transactions. Nothing here is specific to the auction.
module Chain where

import Cardano.Api
import Cardano.Api.Network qualified as Net
import Cardano.Ledger.Compactible (fromCompact)

import Control.Concurrent (threadDelay)
import Data.Function ((&))
import Data.List (find, sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import System.Directory (doesFileExist)

-- ---------------------------------------------------------------------
-- The devnet

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

-- ---------------------------------------------------------------------
-- Wallets

-- | A wallet is a payment key, stored in <name>.skey.
newtype Wallet = Wallet String

instance Show Wallet where
  show (Wallet name) = name

-- | Load the key of a wallet, generating and saving it on first use.
walletKey :: Wallet -> IO (SigningKey PaymentKey)
walletKey (Wallet name) = do
  let path = name <> ".skey"
  exists <- doesFileExist path
  if exists
    then orDie =<< readFileTextEnvelope (File path)
    else do
      skey <- generateSigningKey AsPaymentKey
      _ <- orDie =<< writeFileTextEnvelope (File path) Nothing skey
      pure skey

-- | The key hash of a wallet.
walletKeyHash :: Wallet -> IO (Hash PaymentKey)
walletKeyHash w = verificationKeyHash . getVerificationKey <$> walletKey w

-- | The address of a wallet (fund it with topup).
walletAddress :: Wallet -> IO (Address ShelleyAddr)
walletAddress w = keyHashAddress <$> walletKeyHash w

keyHashAddress :: Hash PaymentKey -> Address ShelleyAddr
keyHashAddress h = makeShelleyAddress network (PaymentCredentialByKey h) NoStakeAddress

scriptAddressOf :: PlutusScript PlutusScriptV3 -> Address ShelleyAddr
scriptAddressOf script =
  makeShelleyAddress network
    (PaymentCredentialByScript (hashScript (PlutusScript PlutusScriptV3 script)))
    NoStakeAddress

-- | An address in its text form (to paste in a topup command).
bech32 :: Address ShelleyAddr -> String
bech32 = Text.unpack . serialiseAddress

-- ---------------------------------------------------------------------
-- Queries

-- | The unspent outputs at an address, largest first.
utxosAt :: Address ShelleyAddr -> IO [(TxIn, TxOut CtxUTxO ConwayEra)]
utxosAt addr = do
  let query = queryUtxo sbe (QueryUTxOByAddress (Set.singleton (toAddressAny addr)))
  result <- executeLocalStateQueryExpr conn Net.VolatileTip query
  UTxO utxo <- orDie =<< orDie =<< orDie result
  pure $ sortOn (\(_, out) -> Down (selectLovelace (outValue out))) (Map.toList utxo)

-- | The largest output of a wallet that holds only ada: it pays for the
-- transaction, and it is the collateral.
adaUtxo :: Wallet -> IO (TxIn, TxOut CtxUTxO ConwayEra)
adaUtxo w = do
  utxos <- utxosAt =<< walletAddress w
  case find (\(_, out) -> length (valueToList (outValue out)) == 1) utxos of
    Just u -> pure u
    Nothing -> fail (show w <> " has no ada: fund it with topup")

-- | The current slot, and what is needed to convert slots to time.
chainTime :: IO (SlotNo, SystemStart, EraHistory)
chainTime = do
  result <- executeLocalStateQueryExpr conn Net.VolatileTip $ do
    point <- queryChainPoint
    start <- querySystemStart
    history <- queryEraHistory
    pure ((,,) <$> point <*> start <*> history)
  (point, start, history) <- orDie =<< orDie result
  case chainPointToSlotNo point of
    Just slot -> pure (slot, start, history)
    Nothing -> fail "the chain has no blocks yet"

-- ---------------------------------------------------------------------
-- Outputs and values

ada :: Integer -> Coin
ada n = Coin (n * 1_000_000)

outValue :: TxOut ctx ConwayEra -> Value
outValue (TxOut _ v _ _) = txOutValueToValue v

outDatum :: TxOut ctx ConwayEra -> Maybe ScriptData
outDatum (TxOut _ _ d _) = case d of
  TxOutDatumInline _ sd -> Just (getScriptData sd)
  _ -> Nothing

valueOut :: Value -> TxOutValue ConwayEra
valueOut v = TxOutValueShelleyBased sbe (toLedgerValue MaryEraOnwardsConway v)

prettyTxIn :: TxIn -> String
prettyTxIn (TxIn txid (TxIx ix)) =
  take 8 (Text.unpack (serialiseToRawBytesHexText txid)) <> "...#" <> show ix

prettyAda :: Coin -> String
prettyAda (Coin l) =
  let (whole, frac) = l `divMod` 1_000_000
      digits = reverse (dropWhile (== '0') (reverse (pad6 (show frac))))
      pad6 s = replicate (6 - length s) '0' <> s
  in show whole <> (if null digits then "" else "." <> digits) <> " ada"

-- ---------------------------------------------------------------------
-- Transactions

-- Note [Balancing a transaction]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- constructBalancedTx computes the fee, adds the change output, runs the
-- Plutus scripts to measure their budget, and signs. It needs the
-- current chain state: queryStateForBalancedTx fetches all of it in one
-- connection. constructBalancedTx does not put the protocol parameters
-- in the transaction body itself, and without them the node rejects the
-- transaction with "ScriptIntegrityHashMismatch", so we set them.

-- | Balance the transaction (the change goes to the wallet), sign it with
-- the wallet key, submit it, and wait until it is in a block.
submitAndWait :: Wallet -> [TxIn] -> TxBodyContent BuildTx ConwayEra -> IO ()
submitAndWait w inputs content = do
  skey <- walletKey w
  changeAddr <- shelleyAddressInEra sbe <$> walletAddress w
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
  let txid = getTxId (getTxBody tx)
  submitTxToNodeLocal conn (TxInMode sbe tx) >>= \case
    TxSubmitSuccess -> pure ()
    failure -> fail (show failure)
  putStrLn ("submitted " <> take 8 (Text.unpack (serialiseToRawBytesHexText txid)) <> "..., waiting for a block")
  waitForTx txid

-- | Wait until the first output of a transaction is on the chain.
waitForTx :: TxId -> IO ()
waitForTx txid = go (60 :: Int)
  where
    go 0 = fail "the transaction is not in a block after 60 seconds"
    go n = do
      let query = queryUtxo sbe (QueryUTxOByTxIn (Set.singleton (TxIn txid (TxIx 0))))
      result <- executeLocalStateQueryExpr conn Net.VolatileTip query
      UTxO utxo <- orDie =<< orDie =<< orDie result
      if Map.null utxo then threadDelay 1_000_000 >> go (n - 1) else pure ()

orDie :: Show e => Either e a -> IO a
orDie = either (fail . show) pure

-- Render a validator rejection by its trace messages, not by the full
-- Show dump of the balancing error.
orDieBalance :: Either (TxBodyErrorAutoBalance ConwayEra) a -> IO a
orDieBalance = \case
  Right a -> pure a
  Left (TxBodyScriptExecutionError [(_, ScriptErrorEvaluationFailed failure)]) ->
    fail $ "the validator rejected the transaction: " <> case dpfExecutionLogs failure of
      [] -> show (dpfEvaluationError failure)
      logs -> show logs
  Left err -> fail (show err)
```

**`Offchain.hs`** has the auction:

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Helpers to run an auction from GHCi against a local devnet: three
-- wallets (the seller, Alice and Bob), and one function for each step of
-- the auction: start, bid, pay out. The plumbing is in Chain.
module Offchain where

import Cardano.Api
import PlutusCore qualified as PLC
import PlutusLedgerApi.Common (serialiseUPLC, uncheckedDeserialiseUPLC)
import UntypedPlutusCore qualified as UPLC

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Function ((&))
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)

import Chain

-- ---------------------------------------------------------------------
-- Wallets

seller, alice, bob :: Wallet
seller = Wallet "seller"
alice = Wallet "alice"
bob = Wallet "bob"

-- | Print the unspent outputs of a wallet.
showWallet :: Wallet -> IO ()
showWallet w = do
  item <- itemAsset
  utxos <- utxosAt =<< walletAddress w
  mapM_ (\(txin, out) -> putStrLn (prettyTxIn txin <> ": " <> prettyValue item (outValue out))) utxos

-- ---------------------------------------------------------------------
-- The item for sale

-- | The item is one token named "item". Its minting policy is a simple
-- script: only the seller's key can mint it.
itemPolicy :: IO SimpleScript
itemPolicy = RequireSignature <$> walletKeyHash seller

itemName :: AssetName
itemName = UnsafeAssetName "item"

itemAsset :: IO AssetId
itemAsset = do
  policy <- itemPolicy
  pure (AssetId (scriptPolicyId (SimpleScript policy)) itemName)

-- ---------------------------------------------------------------------
-- The auction script

-- | The compiled validator, read from the envelope the on-chain project
-- wrote. It is a function of the auction parameters.
auctionValidator :: IO (PlutusScript PlutusScriptV3)
auctionValidator = orDie =<< readFileTextEnvelope (File "auction.plutus")

-- Note [Applying the parameters]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- auction.plutus holds a function. Its first argument is the parameters
-- of an auction, as Data. To get the script of one auction, wrap the
-- program in an application to the parameters:
--
--   (program 1.1.0 validator)  ==>  (program 1.1.0 [validator (con data params)])
--
-- The result is a function of the script context only, as the ledger
-- expects. It is a new script, so it has a new hash and a new address.

-- | Apply the auction parameters to the validator.
applyParams :: PlutusScript PlutusScriptV3 -> ScriptData -> PlutusScript PlutusScriptV3
applyParams (PlutusScriptSerialised bytes) params =
  let UPLC.Program ann version validator = uncheckedDeserialiseUPLC bytes
      arg = UPLC.Constant () (PLC.someValue (toPlutusData params))
  in PlutusScriptSerialised (serialiseUPLC (UPLC.Program ann version (UPLC.Apply () validator arg)))

-- | One running auction: the script with its parameters, its address,
-- and the slot where the bidding ends.
data Auction = Auction
  { auctionScript :: PlutusScript PlutusScriptV3
  , auctionAddress :: Address ShelleyAddr
  , auctionEnd :: SlotNo
  }

instance Show Auction where
  show a = "auction at " <> bech32 (auctionAddress a) <> ", bids until slot " <> show (unSlotNo (auctionEnd a))

-- | The witness that spends the auction output: the script, the inline
-- datum of the output, and the redeemer. The execution units are left at
-- zero: balancing measures them by running the script.
spendWith :: Auction -> ScriptData -> ScriptWitness WitCtxTxIn ConwayEra
spendWith auction redeemer =
  PlutusScriptWitness
    PlutusScriptV3InConway
    PlutusScriptV3
    (PScript (auctionScript auction))
    InlineScriptDatum
    (unsafeHashableScriptData redeemer)
    (ExecutionUnits 0 0)

-- ---------------------------------------------------------------------
-- On-chain data, encoded as ScriptData

-- Note [The on-chain types as ScriptData]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- The validator decodes its parameters, datum and redeemer from Data
-- with the instances of makeIsDataIndexed: a constructor with index i
-- and fields x, y is (Constr i [x, y]). Maybe uses index 0 for Just and
-- 1 for Nothing. So for example the datum "Alice bids 100 ada" is:
--
--   Just (Bid alicePkh 100_000_000)
--     = Constr 0 [Constr 0 [B alicePkh, I 100000000]]

-- AuctionParams seller itemPolicy itemName minBid endTime
paramsData :: Hash PaymentKey -> AssetId -> Coin -> Integer -> ScriptData
paramsData sellerPkh item (Coin minBid) endTime =
  ScriptDataConstructor 0
    [ ScriptDataBytes (serialiseToRawBytes sellerPkh)
    , ScriptDataBytes policyBytes
    , ScriptDataBytes nameBytes
    , ScriptDataNumber minBid
    , ScriptDataNumber endTime
    ]
  where
    (policyBytes, nameBytes) = case item of
      AssetId policy name -> (serialiseToRawBytes policy, serialiseToRawBytes name)
      AdaAssetId -> error "the item cannot be ada"

-- Bid bidder amount
bidData :: Hash PaymentKey -> Coin -> ScriptData
bidData pkh (Coin n) =
  ScriptDataConstructor 0 [ScriptDataBytes (serialiseToRawBytes pkh), ScriptDataNumber n]

-- The datum: Nothing (no bid yet) or Just a bid.
noBidDatum :: ScriptData
noBidDatum = ScriptDataConstructor 1 []

highestBidDatum :: Hash PaymentKey -> Coin -> ScriptData
highestBidDatum pkh amount = ScriptDataConstructor 0 [bidData pkh amount]

-- The redeemers: NewBid bid, and Payout.
newBidRedeemer :: Hash PaymentKey -> Coin -> ScriptData
newBidRedeemer pkh amount = ScriptDataConstructor 0 [bidData pkh amount]

payoutRedeemer :: ScriptData
payoutRedeemer = ScriptDataConstructor 1 []

-- | The highest bid that a datum records, if any.
decodeDatum :: ScriptData -> Maybe (Maybe (Hash PaymentKey, Coin))
decodeDatum = \case
  ScriptDataConstructor 1 [] -> Just Nothing
  ScriptDataConstructor 0 [ScriptDataConstructor 0 [ScriptDataBytes pkh, ScriptDataNumber n]] ->
    case deserialiseFromRawBytes (AsHash AsPaymentKey) pkh of
      Right h -> Just (Just (h, Coin n))
      Left _ -> Nothing
  _ -> Nothing

-- ---------------------------------------------------------------------
-- The auction steps

-- | The ada that goes with the item in an output: every output must hold
-- a minimum amount of ada.
itemDeposit :: Coin
itemDeposit = 2_000_000

-- | Start an auction: mint the item and lock it at the auction address,
-- with no bid in the datum. The bidding ends after the given number of
-- seconds (one slot is one second on the devnet).
startAuction :: Integer -> Integer -> IO Auction
startAuction minBidAda seconds = do
  (tip, systemStart, eraHistory) <- chainTime
  let end = SlotNo (unSlotNo tip + fromInteger seconds)
  endUtc <- orDie (slotToUTCTime systemStart eraHistory end)
  let endTime = floor (utcTimeToPOSIXSeconds endUtc * 1000) -- POSIXTime is in ms
  sellerPkh <- walletKeyHash seller
  item <- itemAsset
  policy <- itemPolicy
  validator <- auctionValidator
  let script = applyParams validator (paramsData sellerPkh item (ada minBidAda) endTime)
      address = scriptAddressOf script
      auctionOutput =
        TxOut
          (shelleyAddressInEra sbe address)
          (valueOut (valueFromList [(item, 1)] <> lovelaceToValue itemDeposit))
          (TxOutDatumInline BabbageEraOnwardsConway (unsafeHashableScriptData noBidDatum))
          ReferenceScriptNone
      policyId = scriptPolicyId (SimpleScript policy)
      mint =
        TxMintValue MaryEraOnwardsConway $
          Map.singleton policyId
            ( PolicyAssets (Map.singleton itemName 1)
            , BuildTxWith (SimpleScriptWitness SimpleScriptInConway (SScript policy))
            )
  (sellerIn, _) <- adaUtxo seller
  submitAndWait seller [sellerIn] $
    defaultTxBodyContent sbe
      & setTxIns [(sellerIn, BuildTxWith (KeyWitness KeyWitnessForSpending))]
      & setTxMintValue mint
      & setTxOuts [auctionOutput]
  pure (Auction script address end)

-- | Bid an amount of ada. The transaction spends the current auction
-- output, creates the new one with the new bid as its datum, and gives
-- the ada of the current auction output back to its owner.
bid :: Auction -> Wallet -> Integer -> IO ()
bid auction w amountAda = do
  (auctionIn, auctionOut) <- currentAuction auction
  sellerPkh <- walletKeyHash seller
  bidderPkh <- walletKeyHash w
  item <- itemAsset
  let amount = ada amountAda
      -- The owner of the ada in the current auction output: the previous
      -- bidder, or the seller (the deposit) before the first bid.
      previousOwner = case outDatum auctionOut >>= decodeDatum of
        Just (Just (pkh, _)) -> pkh
        _ -> sellerPkh
      refund =
        TxOut
          (shelleyAddressInEra sbe (keyHashAddress previousOwner))
          (valueOut (lovelaceToValue (selectLovelace (outValue auctionOut))))
          TxOutDatumNone
          ReferenceScriptNone
      newAuctionOutput =
        TxOut
          (shelleyAddressInEra sbe (auctionAddress auction))
          (valueOut (valueFromList [(item, 1)] <> lovelaceToValue amount))
          (TxOutDatumInline BabbageEraOnwardsConway (unsafeHashableScriptData (highestBidDatum bidderPkh amount)))
          ReferenceScriptNone
  (bidderIn, _) <- adaUtxo w
  submitAndWait w [auctionIn, bidderIn] $
    defaultTxBodyContent sbe
      & setTxIns
          [ (auctionIn, BuildTxWith (ScriptWitness ScriptWitnessForSpending (spendWith auction (newBidRedeemer bidderPkh amount))))
          , (bidderIn, BuildTxWith (KeyWitness KeyWitnessForSpending))
          ]
      & setTxInsCollateral (TxInsCollateral AlonzoEraOnwardsConway [bidderIn])
      -- Valid only up to the end of the bidding.
      & setTxValidityUpperBound (TxValidityUpperBound sbe (Just (auctionEnd auction)))
      & setTxOuts [newAuctionOutput, refund]

-- | Close the auction, after its end: the item goes to the highest bidder
-- and the highest bid to the seller. The seller submits the transaction.
payout :: Auction -> IO ()
payout auction = do
  (tip, _, _) <- chainTime
  unless (tip >= auctionEnd auction) $
    fail $ "too early: the auction ends at slot " <> show (unSlotNo (auctionEnd auction))
      <> ", the chain is at slot " <> show (unSlotNo tip)
  (auctionIn, auctionOut) <- currentAuction auction
  sellerPkh <- walletKeyHash seller
  item <- itemAsset
  let toKey pkh value =
        TxOut (shelleyAddressInEra sbe (keyHashAddress pkh)) (valueOut value) TxOutDatumNone ReferenceScriptNone
      itemValue = valueFromList [(item, 1)] <> lovelaceToValue itemDeposit
      outputs = case outDatum auctionOut >>= decodeDatum of
        Just (Just (winner, amount)) -> [toKey winner itemValue, toKey sellerPkh (lovelaceToValue amount)]
        _ -> [toKey sellerPkh itemValue]
  (sellerIn, _) <- adaUtxo seller
  submitAndWait seller [auctionIn, sellerIn] $
    defaultTxBodyContent sbe
      & setTxIns
          [ (auctionIn, BuildTxWith (ScriptWitness ScriptWitnessForSpending (spendWith auction payoutRedeemer)))
          , (sellerIn, BuildTxWith (KeyWitness KeyWitnessForSpending))
          ]
      & setTxInsCollateral (TxInsCollateral AlonzoEraOnwardsConway [sellerIn])
      -- Valid only from the end of the bidding.
      & setTxValidityLowerBound (TxValidityLowerBound AllegraEraOnwardsConway (auctionEnd auction))
      & setTxOuts outputs

-- | Wait until the bidding is over.
waitForEnd :: Auction -> IO ()
waitForEnd auction = do
  (tip, _, _) <- chainTime
  if tip >= auctionEnd auction
    then putStrLn "the bidding is over"
    else do
      putStrLn (show (unSlotNo (auctionEnd auction - tip)) <> " seconds to go")
      threadDelay 10_000_000
      waitForEnd auction

-- | Send ada to the auction address with a false datum, but without the
-- item. Anyone can do this: an address does not choose what it receives.
fakeBid :: Auction -> Wallet -> Integer -> IO ()
fakeBid auction w amountAda = do
  pkh <- walletKeyHash w
  (walletIn, _) <- adaUtxo w
  let fake =
        TxOut
          (shelleyAddressInEra sbe (auctionAddress auction))
          (valueOut (lovelaceToValue (ada 5)))
          (TxOutDatumInline BabbageEraOnwardsConway (unsafeHashableScriptData (highestBidDatum pkh (ada amountAda))))
          ReferenceScriptNone
  submitAndWait w [walletIn] $
    defaultTxBodyContent sbe
      & setTxIns [(walletIn, BuildTxWith (KeyWitness KeyWitnessForSpending))]
      & setTxOuts [fake]

-- ---------------------------------------------------------------------
-- The auction output

-- | The auction output: the one output at the auction address that holds
-- the item. Other outputs there are not the auction (see fakeBid).
currentAuction :: Auction -> IO (TxIn, TxOut CtxUTxO ConwayEra)
currentAuction auction = do
  item <- itemAsset
  utxos <- utxosAt (auctionAddress auction)
  case find (\(_, out) -> selectAsset (outValue out) item == 1) utxos of
    Just u -> pure u
    Nothing -> fail "no auction output: the auction is over"

-- | Print the outputs at the auction address. Only the output that holds
-- the item is the auction.
showAuction :: Auction -> IO ()
showAuction auction = do
  item <- itemAsset
  names <- walletNames
  utxos <- utxosAt (auctionAddress auction)
  let render (txin, out) =
        prettyTxIn txin <> ": " <> prettyValue item (outValue out)
          <> ", " <> prettyDatum names (outDatum out)
          <> if selectAsset (outValue out) item == 1 then "  <- the auction" else "  (no item: not the auction)"
  mapM_ (putStrLn . render) utxos

walletNames :: IO [(Hash PaymentKey, String)]
walletNames = mapM (\w -> (,show w) <$> walletKeyHash w) [seller, alice, bob]

prettyValue :: AssetId -> Value -> String
prettyValue item v =
  (if selectAsset v item == 1 then "the item + " else "") <> prettyAda (selectLovelace v)

prettyDatum :: [(Hash PaymentKey, String)] -> Maybe ScriptData -> String
prettyDatum names d = case d >>= decodeDatum of
  Just Nothing -> "no bid yet"
  Just (Just (pkh, amount)) ->
    "highest bid: " <> maybe "someone" id (lookup pkh names) <> ", " <> prettyAda amount
  Nothing -> "no auction datum"
```

Read it from top to bottom:

- **Wallets.** There are three: `seller`, `alice` and `bob`.
- **The item.** `itemPolicy` is a *simple script* (a script without Plutus):
  only the seller's key can mint the item.
- **The parameters.** `applyParams` makes the script of one auction from
  `auction.plutus`. Note [Applying the parameters] shows the operation: the
  program becomes an application of the validator to the parameters, as a
  `Data` constant. `scriptAddressOf` then gives the address: the hash of the
  new script.
- **The data.** `paramsData`, `highestBidDatum`, `newBidRedeemer` and the
  others build the `Data` values that the validator decodes. Note [The
  on-chain types as ScriptData] gives the rule, with an example.
- **The steps.** `startAuction`, `bid` and `payout` build one transaction
  each. Compare `bid` with the four rules of `checkBid`: it creates the new
  auction output (rule 4), the refund (rule 3), and sets the upper bound of
  the validity interval to the end of the auction (rule 2).
- **The auction output.** `currentAuction` selects the output at the auction
  address that holds the item. `showAuction` shows all the outputs at the
  address, and marks the auction output.

Each step waits until its transaction is in a block (`waitForTx`), so you can
use the result immediately.

## Step 4: Build the helpers

```console
$ cabal update
$ cabal build
```

Copy the validator in:

```console
$ cp ../auction/auction.plutus .
```

## Step 5: Start the devnet and fund the wallets

Start the devnet as in the lock tutorials:

```console
$ ~/.yaci-devkit/bin/devkit.sh start
```

```
yaci-cli:> create-node -o --start
```

In a second terminal, in `auction-ghci`, connect the project to the node and
start GHCi:

```console
$ socat UNIX-LISTEN:node.sock,fork,reuseaddr TCP:127.0.0.1:3333 &
$ cabal repl
```

Show the three wallet addresses (yours are different):

```
ghci> putStrLn . bech32 =<< walletAddress seller
addr_test1vzjx604ylr2ul20qw9f6gzm5ezlzlgcjqwnsmwqth0d224s9pqjy8
ghci> putStrLn . bech32 =<< walletAddress alice
addr_test1vpn2uf75j7yty66stru6nmhmlanljcfxehgeyulpdtpgyks3x02vq
ghci> putStrLn . bech32 =<< walletAddress bob
addr_test1vpy3yvcp9ku9ezwmtpnfahrxxwza5f03l72e7wrfcu7anmqzgt8t8
```

Send 1000 test ada to each one, at the `devnet:default>` prompt of the first
terminal:

```
devnet:default> topup <seller address> 1000
devnet:default> topup <alice address> 1000
devnet:default> topup <bob address> 1000
```

## Step 6: Run the auction

**Start the auction.** The minimum bid is 50 ada, and the bidding ends after
120 seconds (one slot is one second on the devnet). The seller mints the item
and locks it at the new auction address:

```
ghci> auction <- startAuction 50 120
submitted db479eab..., waiting for a block
ghci> auction
auction at addr_test1wz5lnmldl3rprwq2xnuy8yk2syfhglyw7vhjc4qhakg9jes2g4x4m, bids until slot 8821
ghci> showAuction auction
db479eab...#0: the item + 2 ada, no bid yet  <- the auction
```

This is auction output 1 of the diagram: the item, the deposit of 2 ada, and
"no bid" in the datum. The address is new: it is the hash of the validator
with the parameters of this auction.

**Alice bids 100 ada.**

```
ghci> bid auction alice 100
submitted b2f2aa65..., waiting for a block
ghci> showAuction auction
b2f2aa65...#0: the item + 100 ada, highest bid: alice, 100 ada  <- the auction
```

Auction output 1 is spent, and auction output 2 is at the **same address**:
the datum and the value changed, the script did not. Alice's bid also gave
the deposit back to the seller. Output 1 of Alice's transaction (`#1`) is the
refund, and the other output is the change of the start transaction:

```
ghci> showWallet seller
db479eab...#1: 997.824379 ada
b2f2aa65...#1: 2 ada
```

**Bob bids 150 ada.**

```
ghci> bid auction bob 150
submitted a88724ed..., waiting for a block
ghci> showAuction auction
a88724ed...#0: the item + 150 ada, highest bid: bob, 150 ada  <- the auction
ghci> showWallet alice
b2f2aa65...#2: 899.634265 ada
a88724ed...#1: 100 ada
```

Look at Alice's wallet: `a88724ed...#1` is an output of **Bob's**
transaction. It gives Alice her 100 ada back. Nobody told Alice's wallet:
`showWallet` asks the chain for the outputs at her address, and the refund is
one of them. Her other output is the change of her own bid.

**Alice tries to bid 120 ada.** That is less than Bob's bid:

```
ghci> bid auction alice 120
*** Exception: user error (the validator rejected the transaction: ["bid too low","PT5"])
```

The transaction never reaches the chain. To compute the fee, `cardano-api`
runs the validator, and rule 1 fails with its trace message. `PT5` is the
error code of `check`.

**Bob sends a fake auction output.** Anyone can send funds to an address,
with any datum:

```
ghci> fakeBid auction bob 1000
submitted ce67b1bd..., waiting for a block
ghci> showAuction auction
a88724ed...#0: the item + 150 ada, highest bid: bob, 150 ada  <- the auction
ce67b1bd...#0: 5 ada, highest bid: bob, 1000 ada  (no item: not the auction)
```

Now there are two outputs at the address, and the second one says that the
highest bid is 1000 ada. It does not matter: it does not hold the item, so
`currentAuction` ignores it, and the validator rejects any bid that spends it
(rule 4 needs the item in the new auction output). The 5 ada of Bob are
locked forever: nobody can spend this output.

**The seller tries to close the auction too early:**

```
ghci> payout auction
*** Exception: user error (too early: the auction ends at slot 8821, the chain is at slot 8707)
```

`payout` refuses before it builds the transaction. If it did build it, the
node would reject the transaction: its validity interval would start after
the current slot.

**Wait for the end of the bidding:**

```
ghci> waitForEnd auction
114 seconds to go
...
4 seconds to go
the bidding is over
```

**Alice tries to bid after the end:**

```
ghci> bid auction alice 200
*** Exception: user error (TxSubmitFail (... (OutsideValidityIntervalUTxO (ValidityInterval {invalidBefore = SNothing, invalidHereafter = SJust (SlotNo 8821)}) (SlotNo 8829))) ...))
```

This time the validator accepts the transaction (rule 2: its validity
interval ends at the end time), but the **node** rejects it: the interval
ends at slot 8821, and the chain is at slot 8829. This is how a script can
depend on time without reading a clock.

**Pay out.**

```
ghci> payout auction
submitted 776069a0..., waiting for a block
ghci> showAuction auction
ce67b1bd...#0: 5 ada, highest bid: bob, 1000 ada  (no item: not the auction)
ghci> showWallet bob
ce67b1bd...#1: 844.461656 ada
776069a0...#0: the item + 2 ada
ghci> showWallet seller
776069a0...#2: 995.468125 ada
776069a0...#1: 150 ada
b2f2aa65...#1: 2 ada
```

The auction output is spent, and no new one is created: the auction is over.
Bob has the item, with the 2 ada that the seller added. The seller has Bob's
150 ada. Only the fake output stays at the address.

## Step 7: Shut it down

Exit GHCi, stop the socket bridge, and stop the devkit:

```console
$ kill %1
$ ~/.yaci-devkit/bin/devkit.sh stop
```

## Where to go next

This auction shows the pattern, but it is not ready for real funds:

- **The item can have copies.** The seller's key controls the item's policy,
  so the seller can mint a second item and start a second auction at the same
  address. A real contract uses a *one-shot* minting policy: a policy that
  must spend one given output, so it can mint only once.
- **Bidders cannot cancel.** A bid stays locked until a higher bid or the
  payout.
- **Only one bid per block.** Contracts with many users avoid one shared
  output: for example, each bid is its own output, and one transaction at the
  end selects the highest.

Next steps:

- [Test a Plinth contract locally]({% link how-to/test.md %}): test the rules
  of `checkBid` without a chain.
- [Data representation: Haskell types to Plutus Core]({% link explanation/data-representation.md %}):
  more about the `Data` encoding of `makeIsDataIndexed`.

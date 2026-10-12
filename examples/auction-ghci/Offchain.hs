{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Helpers to run an auction from GHCi against a local devnet: three
-- wallets (the seller, Alice and Bob), and one function for each step of
-- the auction: start, bid, pay out.
module Offchain where

import Cardano.Api
import Cardano.Api.Network qualified as Net
import Cardano.Ledger.Compactible (fromCompact)
import PlutusCore qualified as PLC
import PlutusLedgerApi.Common (serialiseUPLC, uncheckedDeserialiseUPLC)
import UntypedPlutusCore qualified as UPLC

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Function ((&))
import Data.List (find, sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
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

seller, alice, bob :: Wallet
seller = Wallet "seller"
alice = Wallet "alice"
bob = Wallet "bob"

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

-- | The key hash of a wallet: what the auction datum records.
walletKeyHash :: Wallet -> IO (Hash PaymentKey)
walletKeyHash w = verificationKeyHash . getVerificationKey <$> walletKey w

-- | The address of a wallet (fund it with topup).
walletAddress :: Wallet -> IO (Address ShelleyAddr)
walletAddress w = keyHashAddress <$> walletKeyHash w

keyHashAddress :: Hash PaymentKey -> Address ShelleyAddr
keyHashAddress h = makeShelleyAddress network (PaymentCredentialByKey h) NoStakeAddress

-- | An address in its text form (to paste in a topup command).
bech32 :: Address ShelleyAddr -> String
bech32 = Text.unpack . serialiseAddress

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

ada :: Integer -> Coin
ada n = Coin (n * 1_000_000)

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

-- ---------------------------------------------------------------------
-- Plumbing

-- | The auction output: the one output at the auction address that holds
-- the item. Other outputs there are not the auction (see fakeBid).
currentAuction :: Auction -> IO (TxIn, TxOut CtxUTxO ConwayEra)
currentAuction auction = do
  item <- itemAsset
  utxos <- utxosAt (auctionAddress auction)
  case find (\(_, out) -> selectAsset (outValue out) item == 1) utxos of
    Just u -> pure u
    Nothing -> fail "no auction output: the auction is over"

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

scriptAddressOf :: PlutusScript PlutusScriptV3 -> Address ShelleyAddr
scriptAddressOf script =
  makeShelleyAddress network
    (PaymentCredentialByScript (hashScript (PlutusScript PlutusScriptV3 script)))
    NoStakeAddress

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

outValue :: TxOut ctx ConwayEra -> Value
outValue (TxOut _ v _ _) = txOutValueToValue v

outDatum :: TxOut ctx ConwayEra -> Maybe ScriptData
outDatum (TxOut _ _ d _) = case d of
  TxOutDatumInline _ sd -> Just (getScriptData sd)
  _ -> Nothing

valueOut :: Value -> TxOutValue ConwayEra
valueOut v = TxOutValueShelleyBased sbe (toLedgerValue MaryEraOnwardsConway v)

walletNames :: IO [(Hash PaymentKey, String)]
walletNames = mapM (\w -> (,show w) <$> walletKeyHash w) [seller, alice, bob]

prettyTxIn :: TxIn -> String
prettyTxIn (TxIn txid (TxIx ix)) =
  take 8 (Text.unpack (serialiseToRawBytesHexText txid)) <> "...#" <> show ix

prettyAda :: Coin -> String
prettyAda (Coin l) =
  let (whole, frac) = l `divMod` 1_000_000
      digits = reverse (dropWhile (== '0') (reverse (pad6 (show frac))))
      pad6 s = replicate (6 - length s) '0' <> s
  in show whole <> (if null digits then "" else "." <> digits) <> " ada"

prettyValue :: AssetId -> Value -> String
prettyValue item v =
  (if selectAsset v item == 1 then "the item + " else "") <> prettyAda (selectLovelace v)

prettyDatum :: [(Hash PaymentKey, String)] -> Maybe ScriptData -> String
prettyDatum names d = case d >>= decodeDatum of
  Just Nothing -> "no bid yet"
  Just (Just (pkh, amount)) ->
    "highest bid: " <> maybe "someone" id (lookup pkh names) <> ", " <> prettyAda amount
  Nothing -> "no auction datum"

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

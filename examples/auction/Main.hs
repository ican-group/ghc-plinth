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

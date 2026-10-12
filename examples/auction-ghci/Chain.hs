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

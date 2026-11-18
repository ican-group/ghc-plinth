{-# LANGUAGE LambdaCase #-}

-- | The Plinth status of a top-level binding.
--
-- See Note [Plinth status].
module GHC.Plinth.Status
  ( PlinthStatus(..)
  , PlinthBad(..)
  , PlinthCulprit(..)
  , culpritModOcc
  , isPlinthOk
  , plinthStatusForHash
    -- * Binary helpers shared with GHC.Iface.Syntax
  , putBinRealSrcSpan
  , getBinRealSrcSpan
  ) where

import GHC.Prelude

import GHC.Data.FastString
import GHC.Types.Name
import GHC.Types.SrcLoc
import GHC.Unit.Types (Module)
import GHC.Utils.Binary
import GHC.Utils.Outputable

import Control.DeepSeq
import Data.Maybe (fromMaybe)

-- Note [Plinth status]
-- ~~~~~~~~~~~~~~~~~~~~
-- Plinth (Plutus Tx) is a subset of Haskell. The Plinth plugin compiles the
-- argument of each `plinthc e` splice to UPLC, and it can only do so if
-- every binding that `e` reaches is in the subset. This module defines the
-- verdict for one top-level binding:
--
--   PlinthOk       the binding is valid Plinth code, given that the
--                  dictionaries it receives are;
--   PlinthBad      it is not, and pb_culprit names the DIRECT reason: an
--                  imported binding that is itself Bad, or Nothing for a
--                  language feature used in the binding itself (pb_reason
--                  then describes it, e.g. "Int" or "string literal").
--
-- The checker (GHC.Plinth.Check) computes the status at typecheck time and
-- stores it in the IdInfo of the binder, from where it goes to the
-- interface file as an HsPlinthStatus item. At a use site the chain of
-- culprits is rebuilt by following pb_culprit through the interfaces.
--
-- A culprit in the module being compiled is a Name (CulpritName), so that
-- tidy can follow its renaming: a non-exported binder gets a new name
-- there (`$csize` becomes `$fSizeBag_$csize`). In an interface a culprit
-- is a (Module, OccName) pair (CulpritExt) and not a Name: a non-exported
-- binder that tidy did not externalise has no fingerprint, and the
-- interface fingerprinting panics on such a Name. The chain reconstruction
-- resolves the pair when it needs the Id. See 'tidyPlinthStatus' in
-- GHC.Iface.Tidy.
--
-- The status and the culprit are part of the ABI hash of the binding, so a
-- change of status recompiles the dependents. The span is not part of the
-- hash: see 'plinthStatusForHash'.

data PlinthStatus
  = PlinthOk
  | PlinthBad !PlinthBad
  deriving Eq

data PlinthBad = MkPlinthBad
  { pb_culprit :: !(Maybe PlinthCulprit)
    -- ^ The direct culprit, Nothing for a language feature
  , pb_reason  :: !FastString
    -- ^ What is unsupported, e.g. "Int" or "string literal"
  , pb_hint    :: !(Maybe FastString)
    -- ^ What to use instead
  , pb_span    :: !(Maybe RealSrcSpan)
    -- ^ The offending expression in the binding (Nothing if unknown)
  }
  deriving Eq

-- | The direct culprit of a Bad status.
data PlinthCulprit
  = CulpritName !Module !Name
    -- ^ A top-level binder of the module being compiled (the module), as
    -- the typechecker named it; tidy turns it into a CulpritExt
  | CulpritExt !Module !OccName
    -- ^ A binding, type, class or constructor, by name
  deriving Eq

culpritModOcc :: PlinthCulprit -> (Module, OccName)
culpritModOcc (CulpritName m n)  = (fromMaybe m (nameModule_maybe n), nameOccName n)
culpritModOcc (CulpritExt m occ) = (m, occ)

isPlinthOk :: PlinthStatus -> Bool
isPlinthOk PlinthOk = True
isPlinthOk _        = False

-- | The part of the status that goes into the ABI hash: everything but the
-- span. A moved expression must not recompile the dependents.
plinthStatusForHash :: PlinthStatus -> PlinthStatus
plinthStatusForHash PlinthOk        = PlinthOk
plinthStatusForHash (PlinthBad bad) = PlinthBad bad { pb_span = Nothing }

instance Outputable PlinthStatus where
  ppr PlinthOk        = text "Ok"
  ppr (PlinthBad bad) = text "Bad" <+> ppr bad

instance Outputable PlinthBad where
  ppr (MkPlinthBad culprit reason hint span)
    = hsep [ ppr_culprit culprit
           , doubleQuotes (ftext reason)
           , maybe empty (\h -> brackets (ftext h)) hint
           , maybe empty (\s -> parens (ppr s)) span ]
    where
      ppr_culprit Nothing  = text "feature"
      ppr_culprit (Just c) = let (m, occ) = culpritModOcc c in ppr m <> dot <> ppr occ

instance Binary PlinthStatus where
  put_ bh PlinthOk        = putByte bh 0
  put_ bh (PlinthBad bad) = putByte bh 1 >> put_ bh bad
  get bh = getByte bh >>= \case
    0 -> return PlinthOk
    _ -> PlinthBad <$> get bh

-- A culprit is written as a (Module, OccName) pair: see Note [Plinth status].
instance Binary PlinthCulprit where
  put_ bh c = put_ bh (culpritModOcc c)
  get bh = uncurry CulpritExt <$> get bh

instance Binary PlinthBad where
  put_ bh (MkPlinthBad culprit reason hint span) = do
    put_ bh culprit
    put_ bh reason
    put_ bh hint
    case span of
      Nothing -> putByte bh 0
      Just s  -> putByte bh 1 >> putBinRealSrcSpan bh s
  get bh = do
    culprit <- get bh
    reason  <- get bh
    hint    <- get bh
    span    <- getByte bh >>= \case
      0 -> return Nothing
      _ -> Just <$> getBinRealSrcSpan bh
    return (MkPlinthBad culprit reason hint span)

putBinRealSrcSpan :: BinHandle -> RealSrcSpan -> IO ()
putBinRealSrcSpan bh src = do
  put_ bh (srcSpanFile src)
  put_ bh (srcSpanStartLine src)
  put_ bh (srcSpanStartCol src)
  put_ bh (srcSpanEndLine src)
  put_ bh (srcSpanEndCol src)

getBinRealSrcSpan :: BinHandle -> IO RealSrcSpan
getBinRealSrcSpan bh = do
  file <- get bh
  sl <- get bh
  sc <- get bh
  el <- get bh
  ec <- get bh
  return (mkRealSrcSpan (mkRealSrcLoc file sl sc) (mkRealSrcLoc file el ec))

instance NFData PlinthStatus where
  rnf PlinthOk        = ()
  rnf (PlinthBad bad) = rnf bad

instance NFData PlinthBad where
  rnf (MkPlinthBad culprit reason hint span)
    = culprit `seq` reason `seq` hint `seq` span `seq` ()

instance NFData PlinthCulprit where
  rnf c = c `seq` ()

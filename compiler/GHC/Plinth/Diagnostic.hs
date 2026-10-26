{-# LANGUAGE TypeFamilies #-}

-- | The diagnostic of the Plinth gate: code that is not valid Plinth, with
-- the chain of bindings that leads to the unsupported feature.
module GHC.Plinth.Diagnostic
  ( Link(..)
  , PlinthDiagnostic(..)
  , normaliseSpanFile
  ) where

import GHC.Prelude

import GHC.Data.FastString
import GHC.Plinth.Status
import GHC.Types.Error
import GHC.Types.Name.Occurrence (OccName)
import GHC.Types.SrcLoc
import GHC.Unit.Module
import GHC.Utils.Outputable

-- | One binding on the way from the splice to the unsupported feature.
data Link = Link
  { lk_module :: Module
  , lk_occ    :: OccName
  , lk_def    :: Maybe RealSrcSpan   -- ^ definition site
  , lk_home   :: Bool                -- ^ defined in the module being compiled
  }

data PlinthDiagnostic = PlinthNotValid
  { pd_warning :: Bool          -- ^ report as a warning (-fplinth-gate-warn)
  , pd_chain   :: [Link]        -- ^ from the splice's dependency inwards
  , pd_leaf    :: PlinthBad     -- ^ the unsupported feature at the end
  }

instance Diagnostic PlinthDiagnostic where
  type DiagnosticOpts PlinthDiagnostic = NoDiagnosticOpts
  defaultDiagnosticOpts = NoDiagnosticOpts
  diagnosticMessage _ d = mkSimpleDecorated (pprNotValid d)
  diagnosticReason d
    | pd_warning d = WarningWithoutFlag
    | otherwise    = ErrorWithoutFlag
  diagnosticHints _ = []
  diagnosticCode _ = Just (DiagnosticCode "PLINTH" 8)

pprNotValid :: PlinthDiagnostic -> SDoc
pprNotValid (PlinthNotValid { pd_chain = chain, pd_leaf = leaf })
  | null chain, Nothing <- pb_culprit leaf
  = vcat [ text "This code is not valid Plinth:" <+> ftext (pb_reason leaf), nest 2 hint ]
  | otherwise
  = vcat [ text "This code is not valid Plinth:"
         , nest 2 (vcat (zipWith pprLink [0 :: Int ..] chain ++ leafLine))
         , text "Unsupported feature:" <+> ftext (pb_reason leaf) <> hintAfterComma ]
  where
    n = length chain
    -- The leaf is named after the chain when it is a thing with a name
    -- (a type, a class); a feature (a literal pattern, a missing
    -- unfolding) is described by the "Unsupported feature" line only, and
    -- the last link then ends the chain.
    leafLine = case pb_culprit leaf of
      Just c -> [uncurry pprName (culpritModOcc c)]
      Nothing -> []
    pprLink i lk = pprName (lk_module lk) (lk_occ lk) <+> pprWhere lk <+> connective
      where connective | i == n - 1, null leafLine = empty
                       | i == 0 = text "uses"
                       | otherwise = text "which uses"
    hint = maybe empty ftext (pb_hint leaf)
    hintAfterComma = maybe empty (\h -> comma <+> ftext h) (pb_hint leaf)

pprName :: Module -> OccName -> SDoc
pprName m occ = ppr (moduleName m) <> dot <> ppr occ

pprWhere :: Link -> SDoc
pprWhere lk = case (lk_home lk, lk_def lk) of
  (True,  Just sp) -> parens (pprSpan sp)
  (False, Just sp) -> parens (ppr (moduleUnit (lk_module lk)) <> comma <+> pprSpan sp)
  (False, Nothing) -> parens (ppr (moduleUnit (lk_module lk)))
  (True,  Nothing) -> empty

-- | Print a span with a file name that is the same on every platform.
pprSpan :: RealSrcSpan -> SDoc
pprSpan = ppr . normaliseSpanFile

-- | Interface files written on Windows carry backslashes in their file
-- names; the chain must render the same everywhere (golden tests).
normaliseSpanFile :: RealSrcSpan -> RealSrcSpan
normaliseSpanFile sp
  | '\\' `elem` file = mkRealSrcSpan (loc start) (loc end)
  | otherwise = sp
  where
    file = unpackFS (srcSpanFile sp)
    file' = mkFastString (map slash file)
    slash '\\' = '/'
    slash c = c
    start = realSrcSpanStart sp
    end = realSrcSpanEnd sp
    loc l = mkRealSrcLoc file' (srcLocLine l) (srcLocCol l)

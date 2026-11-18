-- | What the Plinth compiler supports by fiat and what it rejects by policy.
--
-- See Note [The Plinth table].
module GHC.Plinth.Table
  ( Verdict(..)
  , tyConVerdict
  , classVerdict
  , idVerdict
  , isTrustedId
  , isPlinthcMarker
  , takesLiteralArgument
  , isBuiltinStringTyCon
  , plinthPluginModuleName
  , modOcc
  ) where

import GHC.Prelude

import GHC.Builtin.Names
import GHC.Builtin.Types
import GHC.Core.Class
import GHC.Core.TyCon
import GHC.Data.FastString
import GHC.Types.Id
import GHC.Types.Name
import GHC.Unit.Module

-- Note [The Plinth table]
-- ~~~~~~~~~~~~~~~~~~~~~~~
-- The Plinth checker (GHC.Plinth.Check) decides most things structurally:
-- it walks the typechecked bindings and the datatypes they use. This table
-- holds the exceptions:
--
--   * types that look fine structurally but have no UPLC representation
--     (Int, Char, Text, ...), with the hint the user should follow;
--
--   * base classes whose methods the plugin never compiles (Eq, Ord, Show,
--     Enum): the user must use the PlutusTx classes;
--
--   * base functions rejected by policy (error, undefined);
--
--   * the primitives: bindings that the plugin maps to UPLC builtins
--     directly, whatever their Haskell body (PlutusTx.Builtins.Internal,
--     the compiler markers, ...). These are "trusted": tagged Ok without a
--     check. The list mirrors the plugin's primitive name table
--     (makePrimitiveNameInfo in plutus-tx-plugin:PlutusTx.Plugin.Common).
--
-- plutus-tx must still build with a stock GHC, so the trusted modules are
-- named here by their module name and not marked in their source with a
-- flag that a stock GHC would reject.

data Verdict
  = VOk
  | VBad FastString (Maybe FastString)   -- ^ reason, hint

-- | The module and occurrence name of an external name, as strings.
modOcc :: Name -> Maybe (String, String)
modOcc n = do
  m <- nameModule_maybe n
  pure (moduleNameString (moduleName m), occNameString (nameOccName n))

-- | The plugin's module name, for its -fplugin-opt options.
plinthPluginModuleName :: ModuleName
plinthPluginModuleName = mkModuleName "Plinth.Plugin"

-- | Is this the 'plinthc' marker, the head of a Plinth splice?
isPlinthcMarker :: Name -> Bool
isPlinthcMarker n = modOcc n == Just ("PlutusTx.Plugin.Utils", "plinthc")

-- | Functions whose string literal argument the plugin handles itself:
-- the builtin string conversions (applied to the literal at compile time)
-- and the runtime errors GHC generates (compiled to a UPLC error), e.g.
-- the fall-through of a record selector of a pattern synonym.
takesLiteralArgument :: Var -> Bool
takesLiteralArgument v = case modOcc (idName v) of
  Just ("PlutusTx.Builtins.HasOpaque", occ) ->
    occ `elem` [ "stringToBuiltinByteString", "stringToBuiltinByteStringUtf8"
               , "stringToBuiltinByteStringHex", "stringToBuiltinString" ]
  Just ("Control.Exception.Base", occ) ->
    occ `elem` [ "recSelError", "patError", "nonExhaustiveGuardsError"
               , "noMethodBindingError", "recConError", "impossibleError"
               , "absentError", "typeError" ]
  _ -> False

-- ---------------------------------------------------------------------------
-- Types

tyConVerdict :: TyCon -> Maybe Verdict
tyConVerdict tc
  | tc == integerTyCon || tc == boolTyCon = Just VOk
  | tc == unboxedUnitTyCon = Just VOk   -- the failure continuation of a pattern synonym matcher
  | tc == intTyCon    = bad "Int"    "use Integer instead"
  | tc == wordTyCon   = bad "Word"   "use Integer instead"
  | tc == charTyCon   = bad "Char"   "use BuiltinString or BuiltinByteString"
  | tc == floatTyCon  = bad "Float"  "use Integer or PlutusTx.Ratio.Rational"
  | tc == doubleTyCon = bad "Double" "use Integer or PlutusTx.Ratio.Rational"
  | n == ioTyConName  = bad "IO" "on-chain code cannot perform IO"
  | n == ratioTyConName = bad "Ratio" "use PlutusTx.Ratio.Rational"
  | Just (m, occ) <- modOcc n = case (m, occ) of
      ("GHC.Int",  _) | occ `elem` ["Int8", "Int16", "Int32", "Int64"]
        -> bad occ "use Integer instead"
      ("GHC.Word", _) | occ `elem` ["Word8", "Word16", "Word32", "Word64"]
        -> bad occ "use Integer instead"
      ("Data.Text.Internal", "Text")
        -> bad "Text" "use BuiltinString"
      ("Data.ByteString.Internal.Type", "ByteString")
        -> bad "ByteString" "use BuiltinByteString"
      ("Data.ByteString.Internal", "ByteString")
        -> bad "ByteString" "use BuiltinByteString"
      ("Data.ByteString.Lazy.Internal", "ByteString")
        -> bad "lazy ByteString" "use BuiltinByteString"
      _ | m `elem` trustedTyConModules -> Just VOk
      _ -> Nothing
  | otherwise = Nothing
  where
    n = tyConName tc
    bad r h = Just (VBad (fsLit r) (Just (fsLit h)))

-- | The builtin types wrap Haskell types that are not valid Plinth; the
-- plugin maps them to UPLC builtin types.
trustedTyConModules :: [String]
trustedTyConModules =
  [ "PlutusTx.Builtins.Internal"
  ]

-- | The builtin string types a string literal may have.
isBuiltinStringTyCon :: TyCon -> Bool
isBuiltinStringTyCon tc = case modOcc (tyConName tc) of
  Just ("PlutusTx.Builtins.Internal", occ) ->
    occ `elem` [ "BuiltinString", "BuiltinByteString" ]
  Just ("PlutusTx.Builtins.HasOpaque", occ) ->
    occ `elem` [ "BuiltinByteStringHex", "BuiltinByteStringUtf8" ]
  _ -> False

-- ---------------------------------------------------------------------------
-- Classes

-- | Classes whose methods the plugin never compiles.
classVerdict :: Class -> Maybe Verdict
classVerdict cls
  | n == eqClassName       = bad "GHC.Classes.Eq"   "use PlutusTx.Eq.Eq"
  | n == ordClassName      = bad "GHC.Classes.Ord"  "use PlutusTx.Ord.Ord"
  | n == showClassName     = bad "GHC.Show.Show"    "use PlutusTx.Show.Show"
  | n == enumClassName     = bad "GHC.Enum.Enum"    "use PlutusTx.Enum.Enum"
  | n == typeableClassName = bad "Typeable" "on-chain code cannot use Typeable"
  | n == ipClassName       = bad "implicit parameter" "pass the value as an argument"
  | otherwise              = Nothing
  where
    n = className cls
    bad r h = Just (VBad (fsLit r) (Just (fsLit h)))

-- ---------------------------------------------------------------------------
-- Ids

-- | Bindings the plugin maps to primitives (Ok by fiat) and base functions
-- rejected by policy. Nothing: decide from the binding's status.
idVerdict :: Id -> Maybe Verdict
idVerdict v
  | isTrustedId v = Just VOk
  | Just (m, occ) <- modOcc (idName v) = case (m, occ) of
      ("GHC.Err", "error")
        -> bad "GHC.Err.error" "use PlutusTx.Prelude.error or PlutusTx.Prelude.traceError"
      ("GHC.Err", "errorWithoutStackTrace")
        -> bad "GHC.Err.errorWithoutStackTrace" "use PlutusTx.Prelude.error or PlutusTx.Prelude.traceError"
      ("GHC.Err", "undefined")
        -> bad "GHC.Err.undefined" "use PlutusTx.Prelude.error or PlutusTx.Prelude.traceError"
      ("Data.ByteString.Internal", "eq")
        -> bad "ByteString equality" "use BuiltinByteString"
      ("PlutusTx.Builtins.HasBuiltin", "toBuiltin")
        -> bad "toBuiltin" "use toOpaque"
      ("PlutusTx.Builtins.HasBuiltin", "fromBuiltin")
        -> bad "fromBuiltin" "use fromOpaque"
      ("GHC.Magic", "lazy")
        -> bad "GHC.Magic.lazy" "on-chain code is strict"
      _ -> Nothing
  | otherwise = Nothing
  where
    bad r h = Just (VBad (fsLit r) (Just (fsLit h)))

-- | The primitives: tagged Ok without looking at the body.
isTrustedId :: Id -> Bool
isTrustedId v = case modOcc (idName v) of
  Nothing -> False
  Just (m, occ)
    | m `elem` trustedModules -> True
    | otherwise -> (m, occ) `elem` trustedNames

trustedModules :: [String]
trustedModules =
  [ "PlutusTx.Builtins.Internal"
  , "PlutusTx.Plugin.Utils"
  , "PlutusTx.Function"
  , "PlutusTx.Optimize.Inline"
  , "PlutusTx.AsData.Internal"
  ]

trustedNames :: [(String, String)]
trustedNames =
  [ ("PlutusTx.Bool", "&&")
  , ("PlutusTx.Bool", "||")
  , ("PlutusTx.Builtins.HasBuiltin", "useToOpaque")
  , ("PlutusTx.Builtins.HasBuiltin", "useFromOpaque")
  , ("PlutusTx.Builtins.HasOpaque", "mkNilOpaque")
  , ("PlutusTx.Builtins.HasOpaque", "stringToBuiltinByteString")
  , ("PlutusTx.Builtins.HasOpaque", "stringToBuiltinByteStringUtf8")
  , ("PlutusTx.Builtins.HasOpaque", "stringToBuiltinByteStringHex")
  , ("PlutusTx.Builtins.HasOpaque", "stringToBuiltinString")
    -- base functions the plugin maps to builtins or handles itself
  , ("GHC.Num.Integer", "integerNegate")
  , ("GHC.Magic", "inline")
  , ("GHC.Magic", "noinline")
  , ("GHC.Prim", "seq")
  , ("GHC.Types", "True")
  , ("GHC.Types", "False")
  ]

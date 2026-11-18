{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Collect, from a typechecked binding, the facts that decide its Plinth
-- status. See Note [The Plinth walk].
module GHC.Plinth.Walk
  ( Fact(..)
  , Facts(..)
  , walkBind
  , walkExpr
  , walkEvTerm
  , collectSplices
  ) where

import GHC.Prelude

import GHC.Builtin.Types (integerTyCon)
import GHC.Core (Expr(..), Bind(..), Alt(..), CoreExpr)
import GHC.Core.ConLike
import GHC.Core.DataCon (dataConTyCon)
import GHC.Core.Multiplicity (Scaled(..))
import GHC.Core.PatSyn (patSynMatcher, patSynBuilder)
import GHC.Core.TyCo.Rep (Type, Coercion)
import GHC.Core.TyCon (TyCon)
import GHC.Core.Type (splitTyConApp_maybe, isTyVarTy)
import GHC.Data.FastString
import GHC.Hs
import GHC.Plinth.Table
import GHC.Tc.Types.Evidence
import GHC.Types.Name hiding (varName)
import GHC.Types.SrcLoc
import GHC.Types.Var
import GHC.Types.Id (isClassOpId_maybe)

import GHC.Data.Bag (bagToList)

import Data.Data hiding (TyCon)
import Data.Semigroup ((<>))

-- Note [The Plinth walk]
-- ~~~~~~~~~~~~~~~~~~~~~~
-- The walk is a generic bottom-up query over the typechecked AST (in the
-- style of GHC.Hs.Dump) that emits facts:
--
--   FVar v        the binding uses the Id v: a top-level binder of the
--                 module, an imported Id, or a local binder (the checker
--                 tells them apart: a top-level binder can have an
--                 internal name, e.g. a derived instance method)
--   FName n       same, for a name whose Id is not at hand (pattern synonym
--                 matchers and builders)
--   FEvVar d      the binding uses the evidence variable d, bound by an
--                 evidence binding of the module (lambda-bound dictionaries
--                 are not in any binding and are opaque)
--   FTyCon tc     the binding constructs or matches a value of tc
--   FType ty      ty is the type of a binder or of an expression
--   FBad r h      the binding uses an unsupported language feature r
--
-- Each fact carries the span of the innermost located node around it. The
-- checker (GHC.Plinth.Check) turns the facts into a verdict.
--
-- Types are never computed: they are read from binders, from the extension
-- fields that the typechecker fills (MatchGroupTc, ConPatTc, ...) and from
-- type applications. Every type that can make a binding invalid appears in
-- one of these places or in the status of an imported Id.
--
-- Overrides handle their own children. Everything else descends
-- generically, which is slow but total: the walk must never panic, base is
-- walked too.

data Fact
  = FVar Var
  | FName Name
  | FEvVar Var
  | FSel Var EvTerm
    -- ^ a class method applied to a dictionary: only the instance's
    -- implementation of the method is used. See Note [Method selection]
  | FLocalSig Var [EvVar]
    -- ^ a local generalised binding and the dictionaries it abstracts
    -- over. See Note [Local dictionary abstractions]
  | FLocalApp Var [EvTerm]
    -- ^ a local binding applied to dictionaries
  | FTyCon TyCon
  | FType Type
  | FBad FastString (Maybe FastString)

-- Note [Method selection]
-- ~~~~~~~~~~~~~~~~~~~~~~~
-- `fromInteger @Integer $fNumInteger 0` must not depend on the whole
-- Num Integer dictionary: GHC resolves the selection of a method of a
-- known instance before the plugin runs (class-op rules in the
-- desugarer's simple optimiser), so only `$fNumInteger_$cfromInteger`
-- is compiled. The walk emits FSel for a class method applied to exactly
-- one dictionary term, and the checker (GHC.Plinth.Check) follows the
-- dictionary to the method implementation when the instance is known.

-- Note [Local dictionary abstractions]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- A local binding that GHC generalises over a class constraint, e.g.
--
--   where go acc (a : tl) | a /= 0 = ...      -- go :: Num a => ...
--
-- takes a dictionary argument, and its call sites pass a known instance
-- (`go @Integer $fNumInteger`). GHC inlines the small wrapper that such a
-- binding desugars to, so the plugin sees the dictionary substituted into
-- the body and compiles only the methods the body selects, never the
-- whole dictionary. The walk records the dictionaries a local binding
-- abstracts over (FLocalSig) and the dictionaries a call passes to it
-- (FLocalApp); the checker joins the two and checks, for each selected
-- method, the implementation of the instance passed.

data Facts = Facts
  { f_facts   :: [(Fact, Maybe RealSrcSpan)]
  , f_evbinds :: [EvBind]
  }

instance Semigroup Facts where
  Facts a b <> Facts c d = Facts (a <> c) (b <> d)

instance Monoid Facts where
  mempty = Facts [] []

-- | Facts of one top-level binding.
walkBind :: Maybe RealSrcSpan -> HsBind GhcTc -> Facts
walkBind = walk

-- | Facts of one expression (the argument of a splice).
walkExpr :: Maybe RealSrcSpan -> LHsExpr GhcTc -> Facts
walkExpr = walk

-- | Facts of an evidence term (the right-hand side of an evidence binding).
walkEvTerm :: Maybe RealSrcSpan -> EvTerm -> Facts
walkEvTerm = walk

-- ---------------------------------------------------------------------------
-- The generic query

extQ :: forall a b r. (Typeable a, Typeable b) => (a -> r) -> (b -> r) -> a -> r
extQ f g a = maybe (f a) g (cast a)

walk :: forall a. Data a => Maybe RealSrcSpan -> a -> Facts
walk sp = generic
  `extQ` lexpr `extQ` expr
  `extQ` lpat  `extQ` pat
  `extQ` lbind `extQ` bind
  `extQ` lmatch `extQ` lgrhs `extQ` lstmt
  `extQ` abexport `extQ` absbinds
  `extQ` overlit `extQ` lit
  `extQ` wrapper
  `extQ` evterm `extQ` tcevbinds `extQ` coreexpr
  `extQ` conlike
  `extQ` scaled `extQ` ty `extQ` co
  `extQ` srcspan `extQ` realsrcspan
  where
    generic :: Data d => d -> Facts
    generic = mconcat . gmapQ (walk sp)

    -- Located nodes refine the span.
    lexpr :: LHsExpr GhcTc -> Facts
    lexpr (L l e) = walk (spanOf l sp) e

    lpat :: LPat GhcTc -> Facts
    lpat (L l p) = walk (spanOf l sp) p

    lbind :: LHsBind GhcTc -> Facts
    lbind (L l b) = walk (spanOf l sp) b

    lmatch :: LMatch GhcTc (LHsExpr GhcTc) -> Facts
    lmatch (L l m) = walk (spanOf l sp) m

    lgrhs :: LGRHS GhcTc (LHsExpr GhcTc) -> Facts
    lgrhs (L l g) = walk (spanOf l sp) g

    lstmt :: LStmt GhcTc (LHsExpr GhcTc) -> Facts
    lstmt (L l s) = walk (spanOf l sp) s

    fact :: Fact -> Facts
    fact f = Facts [(f, sp)] []

    factAt :: Maybe RealSrcSpan -> Fact -> Facts
    factAt s f = Facts [(f, s)] []

    bad :: String -> Maybe String -> Facts
    bad r h = fact (FBad (fsLit r) (fsLit <$> h))

    -- Expressions
    expr :: HsExpr GhcTc -> Facts
    expr e = case e of
      HsVar _ (L l v) -> factAt (spanOf l sp) (FVar v)
      XExpr (WrapExpr (HsWrap w (HsVar _ (L l v))))
        | Just _ <- isClassOpId_maybe v
        , [tm] <- wrapperEvApps w
        -> factAt (spanOf l sp) (FSel v tm) <> wrapperFacts False w
        | not (isExternalName (varName v))
        , tms@(_ : _) <- wrapperEvApps w
        -> factAt (spanOf l sp) (FLocalApp v tms) <> factAt (spanOf l sp) (FVar v)
           <> wrapperFacts False w
      HsUnboundVar {} -> bad "typed hole" Nothing
      HsRecSel _ (FieldOcc sel _) -> fact (FVar sel)
      HsOverLit _ ol -> walk sp ol
      HsLit _ l -> walk sp l
      HsAppType _ f _ _ -> walk sp f   -- the type argument is in the extension field
      -- The builtin string conversions take a string literal: the plugin
      -- compiles the literal itself. See Note [The Plinth table].
      HsApp _ f arg
        | Just v <- headVar f, takesLiteralArgument v, isStringLiteral arg
        -> walk sp f
      NegApp _ (L l inner) syn
        | HsOverLit _ (OverLit (OverLitTc False _ _) (HsIntegral _)) <- inner
        -> walk (spanOf l sp) inner
        | otherwise -> walk sp (L l inner) <> walk sp syn
      ArithSeq _ _ info
        -> bad "range syntax" (Just "use PlutusTx.Enum.enumFromTo or PlutusTx.Enum.enumFromThenTo")
           <> walk sp info
      HsTypedBracket {}   -> bad "Template Haskell quotation" Nothing
      HsUntypedBracket {} -> bad "Template Haskell quotation" Nothing
      HsTypedSplice {}    -> bad "Template Haskell splice" Nothing
      HsProc {}   -> bad "arrow syntax" Nothing
      HsStatic {} -> bad "static pointer" Nothing
      XExpr (ExpansionExpr (HsExpanded _ expanded)) -> walk sp expanded
      XExpr (ConLikeTc con _ _) -> conlike con
      _ -> generic e

    wrapper :: HsWrapper -> Facts
    wrapper = wrapperFacts True

    -- The facts of a wrapper; the evidence applications only on demand.
    -- The innermost wrapper comes first: the type arguments of a function
    -- before its dictionaries, so that `fromIntegral @Int` reports Int
    -- rather than the Integer dictionary.
    wrapperFacts :: Bool -> HsWrapper -> Facts
    wrapperFacts with_ev w = case w of
      WpHole -> mempty
      WpCompose a b -> wrapperFacts with_ev b <> wrapperFacts with_ev a
      WpFun a b (Scaled _ t) -> wrapperFacts with_ev a <> wrapperFacts with_ev b <> fact (FType t)
      WpCast _ -> mempty
      WpEvLam _ -> mempty
      WpEvApp tm | with_ev -> evterm tm
                 | otherwise -> mempty
      WpTyLam _ -> mempty
      WpTyApp t -> fact (FType t)
      WpLet bs -> tcevbinds bs
      WpMultCoercion _ -> mempty

    -- Patterns: binders give their types, literals are rejected.
    pat :: Pat GhcTc -> Facts
    pat p = case p of
      VarPat _ (L _ v) -> fact (FType (varType v))
      AsPat _ (L _ v) _ inner -> fact (FType (varType v)) <> walk sp inner
      LitPat {} -> literalPattern
      -- Note [Literal patterns]
      -- ~~~~~~~~~~~~~~~~~~~~~~~
      -- An overloaded literal pattern compares with == of its type. On
      -- Integer that is integerEq, which the plugin maps to a builtin,
      -- unless GHC has inlined it first (it does when the result of the
      -- match is scrutinised), and then the plugin fails on the IS/IP/IN
      -- match. The outcome depends on the optimiser, so the check rejects
      -- literal patterns: a guard with PlutusTx.Eq.== is the stable form.
      NPat {} -> literalPattern
      NPlusKPat {} -> literalPattern
      XPat (ExpansionPat _ expanded) -> walk sp expanded
      _ -> generic p
      where
        literalPattern =
          bad "literal pattern" (Just "compare with PlutusTx.Eq.== in a guard")

    -- Nested bindings: binder types, then the generic descent.
    bind :: HsBind GhcTc -> Facts
    bind b = case b of
      FunBind { fun_id = L _ v } -> fact (FType (varType v)) <> generic b
      VarBind { var_id = v }     -> fact (FType (varType v)) <> generic b
      _ -> generic b

    abexport :: ABExport -> Facts
    abexport (ABE { abe_poly = v, abe_wrap = w })
      = fact (FType (varType v)) <> walk sp w

    -- A generalised binding: the dictionaries it abstracts over.
    absbinds :: AbsBinds -> Facts
    absbinds ab@(AbsBinds { abs_ev_vars = ds, abs_exports = es })
      = mconcat [ fact (FLocalSig (abe_poly e) ds) | not (null ds), e <- es ]
        <> generic ab

    -- Literals
    lit :: HsLit GhcTc -> Facts
    lit l = case l of
      HsInteger {} -> mempty
      HsString {}  -> bad "string literal"
                        (Just "use OverloadedStrings with BuiltinString or BuiltinByteString")
      HsChar {}    -> bad "Char literal" (Just "use BuiltinString or BuiltinByteString")
      HsInt {}     -> bad "Int literal" (Just "use Integer")
      HsRat {}     -> bad "fractional literal" (Just "use PlutusTx.Ratio")
      _            -> bad "unboxed literal" Nothing

    overlit :: HsOverLit GhcTc -> Facts
    overlit (OverLit (OverLitTc { ol_witness = witness, ol_type = t }) val)
      = case val of
          -- At an unsupported type the type is the whole problem: the
          -- witness (fromInteger of that type) would only repeat it.
          HsIntegral _
            | isIntegerType t -> mempty
            | isBadTyCon t -> fact (FType t)
            | otherwise -> fact (FType t) <> walk sp witness
          HsFractional _ -> bad "fractional literal" (Just "use PlutusTx.Ratio")
          HsIsString _ _
            | isBuiltinStringType t || isTyVarTy t -> mempty
            | isBadTyCon t -> fact (FType t)
            | otherwise -> fact (FType t) <> walk sp witness

    -- Evidence
    evterm :: EvTerm -> Facts
    evterm (EvExpr e) = coreexpr e
    evterm (EvTypeable _ _) = bad "Typeable" Nothing
    evterm (EvFun { et_binds = bs, et_body = body })
      = walk sp bs <> fact (FEvVar body)

    tcevbinds :: TcEvBinds -> Facts
    tcevbinds (EvBinds bs) = Facts [] (bagToList bs)
    tcevbinds (TcEvBinds _) = mempty   -- not zonked: cannot happen

    coreexpr :: CoreExpr -> Facts
    coreexpr ce = case ce of
      Var v | isExternalName (varName v) -> fact (FVar v)
            | isId v -> fact (FEvVar v)
            | otherwise -> mempty
      Lit _ -> mempty
      App f a -> coreexpr f <> coreexpr a
      Lam _ body -> coreexpr body
      Let (NonRec _ rhs) body -> coreexpr rhs <> coreexpr body
      Let (Rec bs) body -> mconcat (map (coreexpr . snd) bs) <> coreexpr body
      Case s _ _ alts -> coreexpr s <> mconcat [ coreexpr rhs | Alt _ _ rhs <- alts ]
      Cast e _ -> coreexpr e
      Tick _ e -> coreexpr e
      Type t -> fact (FType t)
      Coercion _ -> mempty

    -- Constructors
    conlike :: ConLike -> Facts
    conlike (RealDataCon dc)
      | dataConTyCon dc == integerTyCon
      = bad "the representation of Integer" (Just "use the Integer operations of PlutusTx.Prelude")
      | otherwise = fact (FTyCon (dataConTyCon dc))
    conlike (PatSynCon ps)
      = fact (FName matcher) <> maybe mempty (fact . FName) builder
      where
        (matcher, _, _) = patSynMatcher ps
        builder = case patSynBuilder ps of
          Just (n, _, _) -> Just n
          Nothing -> Nothing

    -- Types stop the generic descent; coercions are erased. The
    -- multiplicity of a Scaled type is a type too (Many): skip it.
    scaled :: Scaled Type -> Facts
    scaled (Scaled _ t) = fact (FType t)

    ty :: Type -> Facts
    ty t = fact (FType t)

    co :: Coercion -> Facts
    co _ = mempty

    srcspan :: SrcSpan -> Facts
    srcspan _ = mempty

    realsrcspan :: RealSrcSpan -> Facts
    realsrcspan _ = mempty

-- | The variable at the head of an expression, through parentheses,
-- wrappers and type applications.
headVar :: LHsExpr GhcTc -> Maybe Var
headVar (L _ e) = case e of
  HsVar _ (L _ v) -> Just v
  HsPar _ _ inner _ -> headVar inner
  HsAppType _ inner _ _ -> headVar inner
  XExpr (WrapExpr (HsWrap _ inner)) -> headVar (L noSrcSpanA inner)
  _ -> Nothing

-- | A string literal, plain or overloaded.
isStringLiteral :: LHsExpr GhcTc -> Bool
isStringLiteral (L _ e) = case e of
  HsLit _ (HsString {}) -> True
  HsLit _ (HsStringPrim {}) -> True
  HsOverLit _ (OverLit _ (HsIsString {})) -> True
  HsPar _ _ inner _ -> isStringLiteral inner
  XExpr (WrapExpr (HsWrap _ inner)) -> isStringLiteral (L noSrcSpanA inner)
  _ -> False

-- | The evidence terms a wrapper applies, in order.
wrapperEvApps :: HsWrapper -> [EvTerm]
wrapperEvApps w = case w of
  WpCompose a b -> wrapperEvApps a ++ wrapperEvApps b
  WpEvApp tm -> [tm]
  _ -> []

spanOf :: SrcSpanAnn' a -> Maybe RealSrcSpan -> Maybe RealSrcSpan
spanOf l outer = case locA l of
  RealSrcSpan s _ -> Just s
  _ -> outer

isIntegerType :: Type -> Bool
isIntegerType t = case splitTyConApp_maybe t of
  Just (tc, []) -> tc == integerTyCon
  _ -> False

-- | A type whose head is a type constructor of the table's Bad list.
isBadTyCon :: Type -> Bool
isBadTyCon t = case splitTyConApp_maybe t of
  Just (tc, _) | Just (VBad {}) <- tyConVerdict tc -> True
  _ -> False

isBuiltinStringType :: Type -> Bool
isBuiltinStringType t = case splitTyConApp_maybe t of
  Just (tc, []) -> isBuiltinStringTyCon tc
  _ -> False

-- ---------------------------------------------------------------------------
-- Splices

-- | The arguments of the 'plinthc' markers in a binding: the on-chain
-- expressions that the gate must validate.
collectSplices :: Data a => a -> [LHsExpr GhcTc]
collectSplices = generic `extQ` expr
  where
    generic :: Data d => d -> [LHsExpr GhcTc]
    generic = concat . gmapQ collectSplices

    expr :: HsExpr GhcTc -> [LHsExpr GhcTc]
    expr e = case e of
      HsApp _ f arg | isMarkerHead f -> [arg]
      _ -> generic e

    isMarkerHead :: LHsExpr GhcTc -> Bool
    isMarkerHead (L _ f) = case f of
      HsVar _ (L _ v) -> isPlinthcMarker (varName v)
      HsPar _ _ inner _ -> isMarkerHead inner
      HsAppType _ inner _ _ -> isMarkerHead inner
      XExpr (WrapExpr (HsWrap _ inner)) -> isMarkerHead (L noSrcSpanA inner)
      _ -> False

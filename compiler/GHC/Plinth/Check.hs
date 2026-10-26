{-# LANGUAGE LambdaCase #-}

-- | The Plinth checker: tag every top-level binding with its Plinth status
-- and validate the Plinth splices of the module.
--
-- See Note [Plinth status] in GHC.Plinth.Status and Note [The Plinth walk]
-- in GHC.Plinth.Walk.
module GHC.Plinth.Check
  ( plinthCheckModule
  ) where

import GHC.Prelude

import GHC.Core (isCompulsoryUnfolding, hasSomeUnfolding, isBootUnfolding, Unfolding(..), Expr(..), collectArgs, mkApps, isTypeArg)
import GHC.Core.Class (className, classMethods, classAllSelIds)
import GHC.Core.DataCon
import GHC.Core.FamInstEnv (normaliseType)
import GHC.Core.Reduction (reductionReducedType)
import GHC.Core.TyCo.Rep
import GHC.Builtin.Types (integerTyCon)
import GHC.Builtin.Types.Prim (fUNTyCon)
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Data.Bag
import GHC.Data.FastString (fsLit)
import qualified GHC.Data.Strict as Strict
import GHC.Driver.Session
import GHC.Hs
import GHC.Iface.Env (lookupOrig)
import GHC.Plinth.Diagnostic
import GHC.Plinth.Status
import GHC.Plinth.Table
import GHC.Plinth.Walk
import GHC.Tc.Errors.Types (mkTcRnUnknownMessage)
import GHC.Tc.Instance.Family (tcGetFamInstEnvs)
import GHC.Tc.Types
import GHC.Tc.Types.Evidence
import GHC.Tc.Utils.Env (tcLookupId, tcLookupGlobal, setGlobalTypeEnv)
import GHC.Tc.Utils.Monad
import GHC.Types.Id
import GHC.Types.Id.Info (IdDetails(..))
import GHC.Types.Name
import GHC.Types.Name.Env
import GHC.Types.SourceFile (isHsBootOrSig)
import GHC.Types.SrcLoc
import GHC.Types.TypeEnv (extendTypeEnvWithIds)
import GHC.Types.Unique.Set (nonDetEltsUniqSet)
import GHC.Types.Var
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.TyThing (TyThing(..))
import GHC.Unit.Module
import GHC.Unit.Module.ModSummary
import GHC.Utils.Error (withTiming)
import GHC.Utils.Logger
import GHC.Utils.Outputable

import Control.Applicative ((<|>))
import Control.Monad
import Data.IORef
import qualified Data.IntMap.Strict as IM
import Data.List (sortOn, elemIndex)
import Data.Maybe

-- Note [The Plinth checker]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~
-- plinthCheckModule runs at the end of typechecking, before the
-- typechecker plugins, on the zonked bindings. It does, in order:
--
--  1. walk every top-level binding (GHC.Plinth.Walk) and resolve the
--     evidence variables through the evidence bindings of the module;
--
--  2. give every binding a direct verdict: Bad for the first unsupported
--     feature, type, constructor or imported binding it uses; otherwise Ok
--     with the list of the same-module bindings it depends on;
--
--  3. propagate Bad along the dependencies until a fixpoint. A recursive
--     group whose members are all directly fine is Ok;
--
--  4. put the status on the binder Ids, in tcg_binds and tcg_type_env, so
--     that the desugarer, tidy and the interface see it;
--
--  5. the gate: for every `plinthc e` splice, report each unsupported
--     dependency of e with the chain of bindings that leads to it.
--
-- Polymorphic bindings are Ok at their definition: their dictionaries are
-- lambda-bound, so they are opaque. The use site passes concrete
-- dictionary functions, which carry their own status.

plinthCheckModule :: ModSummary -> TcGblEnv -> TcM TcGblEnv
plinthCheckModule mod_sum tcg_env = do
  dflags <- getDynFlags
  if not (gopt Opt_PlinthStatus dflags) || isHsBootOrSig (ms_hsc_src mod_sum)
    then return tcg_env
    else do
      logger <- getLogger
      withTiming logger (text "Plinth status" <+> brackets (ppr (tcg_mod tcg_env)))
                 (const ()) $
        checkModule dflags logger tcg_env

-- ---------------------------------------------------------------------------
-- Environment

data CheckEnv = CheckEnv
  { ce_mod     :: Module
  , ce_dflags  :: DynFlags
  , ce_binders :: NameEnv Int              -- ^ top-level binder -> node
  , ce_evbinds :: VarEnv EvTerm            -- ^ evidence bindings of the module
  , ce_dfuns   :: NameEnv [Maybe Id]       -- ^ same-module dfun -> its method implementations
  , ce_tycons  :: IORef (NameEnv TyConState)
  , ce_stack   :: IORef [TyCon]            -- ^ tycons being checked, innermost first
  }

data TyConState = InProgress | Done (Maybe PlinthBad)

data Node = Node
  { nd_id      :: Int
  , nd_binders :: [Id]
  , nd_span    :: SrcSpan
  , nd_facts   :: [(Fact, Maybe RealSrcSpan)]
  }

-- | What a binding knows about its local dictionary abstractions.
-- See Note [Local dictionary abstractions] in GHC.Plinth.Walk.
data NodeCtx = NodeCtx
  { nc_sigs    :: VarEnv [EvVar]      -- ^ local binding -> the dictionaries it abstracts over
  , nc_sels    :: VarEnv [Id]         -- ^ dictionary variable -> the methods selected from it
  , nc_apps    :: [(Var, [EvTerm])]   -- ^ the local applications (for the flow of a dictionary)
  , nc_escapes :: VarSet              -- ^ dictionary variables used as values
  }

mkNodeCtx :: CheckEnv -> [(Fact, Maybe RealSrcSpan)] -> NodeCtx
mkNodeCtx env facts = NodeCtx
  { nc_sigs = mkVarEnv [ (p, ds) | (FLocalSig p ds, _) <- facts ]
  , nc_sels = foldr (\(d, s) acc -> extendVarEnv_C (++) acc d [s]) emptyVarEnv
                [ (dictVar env d, sel) | (FSel sel (EvExpr (Var d)), _) <- facts ]
  , nc_apps = [ (p, map (dictTerm env) tms) | (FLocalApp p tms, _) <- facts ]
  , nc_escapes = mkVarSet [ d | (FEvVar d, _) <- facts ]
  }

-- | Follow the evidence bindings of the form @d = d'@ to the variable at
-- the end: the dictionary parameter of a local binding is often reached
-- through such aliases.
dictVar :: CheckEnv -> EvVar -> EvVar
dictVar env = go emptyVarSet
  where
    go visited d
      | d `elemVarSet` visited = d
      | Just (EvExpr (Var d')) <- lookupVarEnv (ce_evbinds env) d = go (extendVarSet visited d) d'
      | otherwise = d

dictTerm :: CheckEnv -> EvTerm -> EvTerm
dictTerm env (EvExpr (Var d)) = EvExpr (Var (dictVar env d))
dictTerm _ tm = tm

-- | The methods selected from a dictionary variable, also through the
-- local bindings it is passed to.
selectedFrom :: NodeCtx -> EvVar -> ([Id], Bool)
selectedFrom ctx = go emptyVarSet
  where
    go visited d
      | d `elemVarSet` visited = ([], False)
      | d `elemVarSet` nc_escapes ctx = ([], True)
      | otherwise =
          let direct = fromMaybe [] (lookupVarEnv (nc_sels ctx) d)
              through = [ go (extendVarSet visited d) d'
                        | (p, tms) <- nc_apps ctx
                        , Just ds <- [lookupVarEnv (nc_sigs ctx) p]
                        , (d', EvExpr (Var v)) <- zip ds tms, v == d ]
          in (direct ++ concatMap fst through, any snd through)

-- | The verdict on one fact.
data FactResult
  = FrOk
  | FrDep Int Var (Maybe RealSrcSpan)   -- ^ depends on a same-module node
  | FrBad PlinthBad

-- | The direct verdict on a node.
data Direct = Direct
  { dr_bad  :: Maybe PlinthBad
  , dr_deps :: [(Int, Var, Maybe RealSrcSpan)]
  }

-- ---------------------------------------------------------------------------
-- The module

checkModule :: DynFlags -> Logger -> TcGblEnv -> TcM TcGblEnv
checkModule dflags logger tcg_env = do
  let this_mod = tcg_mod tcg_env
      binds = bagToList (tcg_binds tcg_env)
      walked = [ (lb, walkBind (srcSpanToRealSrcSpan (locA l)) b) | lb@(L l b) <- binds ]
      nodes = [ Node { nd_id = i
                     , nd_binders = collectHsBindBinders CollNoDictBinders b
                     , nd_span = locA l
                     , nd_facts = f_facts facts }
              | (i, (L l b, facts)) <- zip [0 ..] walked ]
      ev_binds = bagToList (tcg_ev_binds tcg_env) ++ concatMap (f_evbinds . snd) walked
      binders = [ (v, nd_id n) | n <- nodes, v <- nd_binders n ]
  tycons <- liftIO (newIORef emptyNameEnv)
  stack <- liftIO (newIORef [])
  let env = CheckEnv
        { ce_mod = this_mod
        , ce_dflags = dflags
        , ce_binders = mkNameEnv [ (idName v, i) | (v, i) <- binders ]
        , ce_evbinds = mkVarEnv [ (eb_lhs eb, eb_rhs eb) | eb <- ev_binds ]
        , ce_dfuns = mkNameEnv (concatMap (dfunMethods . unLoc) binds)
        , ce_tycons = tycons
        , ce_stack = stack }

  -- 2. direct verdicts
  directs <- mapM (directVerdict env) nodes

  -- 3. propagation
  let statuses = propagate this_mod nodes directs
      status_of name = do
        i <- lookupNameEnv (ce_binders env) name
        IM.lookup i statuses
      node_ids = mkNameEnv [ (idName v, v) | n <- nodes, v <- nd_binders n ]

  -- 4. tagging
  let binds' = [ L l (tagBind status_of b) | L l b <- binds ]
      new_ids = concat [ collectHsBindBinders CollNoDictBinders b | L _ b <- binds' ]
  tcg_env' <- setGlobalTypeEnv tcg_env (extendTypeEnvWithIds (tcg_type_env tcg_env) new_ids)
  let tcg_env'' = tcg_env' { tcg_binds = listToBag binds' }

  -- 5. the gate
  let mode = gateMode dflags
  verdicts <- if mode == GateOff
    then return []
    else fmap concat $ forM binds $ \(L _ b) ->
      forM (collectSplices b) $ \arg -> gateSplice env node_ids statuses mode arg

  -- the dump
  liftIO $ putDumpFileMaybe logger Opt_D_dump_plinth_status "Plinth status" FormatText $
    vcat [ text "Bindings:"
         , nest 2 (vcat [ ppr (idName v) <+> dcolon <+> ppr st
                        | (st, v) <- sortOn (srcSpanToRealSrcSpan . nameSrcSpan . idName . snd)
                            [ (st, v) | n <- nodes, v <- nd_binders n
                            , Just st <- [IM.lookup (nd_id n) statuses] ] ])
         , text "Splices:" <+> int (length verdicts) <+> text "checked,"
             <+> int (length (filter not verdicts)) <+> text "rejected" ]
  return tcg_env''

-- ---------------------------------------------------------------------------
-- Evidence

-- | Replace the evidence variables bound in the module by the facts of
-- their right-hand sides. Variables bound nowhere are lambda-bound
-- dictionaries: opaque.
resolveEvidence :: CheckEnv -> [(Fact, Maybe RealSrcSpan)] -> [(Fact, Maybe RealSrcSpan)]
resolveEvidence env = go emptyVarSet (ce_evbinds env)
  where
    go _ _ [] = []
    go seen evs ((FEvVar v, sp) : rest)
      | v `elemVarSet` seen = go seen evs rest
      | Just _ <- lookupVarEnv evs v
      -- Solved evidence of a class the table rejects: one fact, instead
      -- of the facts of the evidence term (a HasCallStack term mentions
      -- call stacks, Int and String).
      , Just (VBad r h) <- evVarClassVerdict v
      = (FBad r h, sp) : go (extendVarSet seen v) evs rest
      | Just tm <- lookupVarEnv evs v
      = let Facts facts more = walkEvTerm sp tm
            evs' = extendVarEnvList evs [ (eb_lhs eb, eb_rhs eb) | eb <- more ]
        in go (extendVarSet seen v) evs' (facts ++ rest)
      | otherwise = go seen evs rest
    go seen evs (f : rest) = f : go seen evs rest

    evVarClassVerdict v = do
      (tc, _) <- splitTyConApp_maybe (varType v)
      cls <- tyConClass_maybe tc
      classVerdict cls

-- ---------------------------------------------------------------------------
-- Direct verdicts

directVerdict :: CheckEnv -> Node -> TcM Direct
directVerdict env node = go [] facts
  where
    facts = resolveEvidence env (nd_facts node)
    ctx = mkNodeCtx env facts

    go deps [] = return (Direct Nothing (reverse deps))
    go deps (fact : rest) = factVerdict env ctx fact >>= \case
      FrOk -> go deps rest
      FrDep i v sp -> go ((i, v, sp) : deps) rest
      FrBad bad -> return (Direct (Just bad) (reverse deps))

-- | The culprit for a name: a binder of this module keeps its Name (tidy
-- renames it), anything else is identified by module and occurrence name.
-- A same-module name can be internal (e.g. the methods of a derived
-- instance): then its module is the module being compiled.
culpritOf :: CheckEnv -> Name -> PlinthCulprit
culpritOf env n
  | Just _ <- lookupNameEnv (ce_binders env) n = CulpritName this_mod n
  | otherwise = CulpritExt (fromMaybe this_mod (nameModule_maybe n)) (nameOccName n)
  where this_mod = ce_mod env

-- | The method implementations of a same-module instance, in the order
-- of the class methods, from the dictionary binding that the typechecker
-- generates: @$fC = C:C @ty sc_dicts meth_1 ... meth_n@ (the superclass
-- dictionaries come through the wrapper, the methods are the arguments).
-- See Note [Method selection] in GHC.Plinth.Walk.
dfunMethods :: HsBind GhcTc -> [(Name, [Maybe Id])]
dfunMethods (XHsBindsLR (AbsBinds { abs_exports = es, abs_binds = inner }))
  = [ (idName (abe_poly e), args)
    | e <- es, isDFunId (abe_poly e)
    , Just args <- [listToMaybe [ conArgs rhs
                                | L _ (VarBind { var_id = v, var_rhs = rhs }) <- bagToList inner
                                , v == abe_mono e ]] ]
  where
    conArgs :: LHsExpr GhcTc -> [Maybe Id]
    conArgs e = case strip e of
      HsApp _ f a -> conArgs f ++ [argId a]
      _ -> []
    argId a = case strip a of
      HsVar _ (L _ v) -> Just v
      _ -> Nothing
    strip (L _ e) = case e of
      HsPar _ _ inner' _ -> strip inner'
      XExpr (WrapExpr (HsWrap _ inner')) -> strip (L noSrcSpanA inner')
      HsAppType _ inner' _ _ -> strip inner'
      _ -> e
dfunMethods _ = []

-- Note [No unfolding at the use site]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- The plugin compiles an imported binding from the unfolding in its
-- interface. A NOINLINE or OPAQUE pragma, or -fomit-interface-pragmas,
-- leaves no unfolding there. Within its own module the binding compiles
-- fine (the plugin has the Core), so the status of the binding describes
-- its body and the availability of the unfolding is checked where the
-- binding is imported.

-- | The verdict on one fact, with the span of the fact as the span of the
-- verdict.
factVerdict :: CheckEnv -> NodeCtx -> (Fact, Maybe RealSrcSpan) -> TcM FactResult
factVerdict env ctx (fact, sp) = case fact of
  FBad r h  -> bad (MkPlinthBad Nothing r h sp)
  FEvVar v  -> localOrDep v
  FType t   -> located <$> checkType env t
  FTyCon tc -> located <$> checkTyCon env tc
  FName n   -> do v <- tcLookupId n; varVerdict v
  FVar v    -> varVerdict v
  FSel v tm -> selFact v tm
  FLocalSig _ _ -> return FrOk
  FLocalApp p tms -> case lookupVarEnv (nc_sigs ctx) p of
    Nothing -> wholeDicts tms
    Just ds -> firstResult =<< mapM dictArg (zip ds tms)
  where
    -- See Note [Local dictionary abstractions] in GHC.Plinth.Walk
    dictArg (d, tm) = case selectedFrom ctx d of
      (_, True) -> wholeDicts [tm]
      (sels, False) -> firstResult =<< mapM (\sel -> selFact sel tm) sels

    wholeDicts tms = firstResult =<< mapM (factVerdict env ctx)
                       (concat [ f_facts (walkEvTerm sp tm) | tm <- tms ])

    selFact v tm
      | Just cls <- isClassOpId_maybe v
      , Just verdict <- classVerdict cls = fromVerdict (className cls) verdict
      | Just cls <- isClassOpId_maybe v = selVerdict cls v emptyVarSet tm
      | otherwise = varVerdict v

    bad = return . FrBad
    located = maybe FrOk (\b -> FrBad b { pb_span = sp })

    varVerdict v
      | Just verdict <- idVerdict v = fromVerdict (idName v) verdict
      | Just cls <- isClassOpId_maybe v
      = maybe (return FrOk) (fromVerdict (className cls)) (classVerdict cls)
      | Just dc <- isDataConId_maybe v
      = if dataConTyCon dc == integerTyCon
          then bad (MkPlinthBad culprit (fsLit "the representation of Integer")
                      (Just (fsLit "use the Integer operations of PlutusTx.Prelude")) sp)
          else located <$> checkTyCon env (dataConTyCon dc)
      | PrimOpId {} <- idDetails v
      = bad (MkPlinthBad culprit (fsLit "primitive operation") Nothing sp)
      | FCallId {} <- idDetails v
      = bad (MkPlinthBad culprit (fsLit "foreign call") Nothing sp)
      | Just i <- lookupNameEnv (ce_binders env) (idName v) = return (FrDep i v sp)
      | not (isExternalName (idName v)) = return FrOk    -- a local binder
      | otherwise = case idPlinthStatus v of
          -- Note [No unfolding at the use site]
          Just PlinthOk
            | hasSomeUnfolding (idUnfolding v) -> return FrOk
            | otherwise -> bad (MkPlinthBad culprit (fsLit "no unfolding")
                                  (Just (fsLit "remove its NOINLINE or OPAQUE pragma, or -fomit-interface-pragmas from its module")) sp)
          Just (PlinthBad b) -> bad (MkPlinthBad culprit (pb_reason b) (pb_hint b) sp)
          Nothing
            | nameIsLocalOrFrom (ce_mod env) (idName v) -> return FrOk
            | isWiredInName (idName v) -> return FrOk
            | isCompulsoryUnfolding (idUnfolding v) -> return FrOk
            | isBootUnfolding (idUnfolding v)
            -> bad (MkPlinthBad culprit (fsLit "imported through an hs-boot file")
                      (Just (fsLit "import the module itself")) sp)
            | otherwise -> bad (MkPlinthBad culprit (fsLit "built without the Plinth checker")
                                  (Just (fsLit "build the package with plinthc")) sp)
      where
        culprit = Just (culpritOf env (idName v))

    -- An evidence variable that no evidence binding defines: a same-module
    -- binder (then a dependency) or a lambda-bound dictionary (opaque).
    localOrDep v
      | Just i <- lookupNameEnv (ce_binders env) (idName v) = return (FrDep i v sp)
      | otherwise = return FrOk

    -- A method of class cls selected from the dictionary tm: follow the
    -- dictionary to the instance and use the method's implementation.
    -- See Note [Method selection] in GHC.Plinth.Walk.
    selVerdict cls sel visited tm = case tm of
      EvExpr e
        | (Var d, args) <- collectArgs e -> dictVerdict cls sel visited d args
      _ -> firstResult =<< mapM (factVerdict env ctx) (f_facts (walkEvTerm sp tm))

    dictVerdict cls sel visited d args
      -- an evidence variable bound in the module: follow it
      | Just tm' <- lookupVarEnv (ce_evbinds env) d
      , not (d `elemVarSet` visited)
      = selVerdict cls sel (extendVarSet visited d) tm'
      -- a same-module instance: the method binding
      | isDFunId d
      , Just meths <- lookupNameEnv (ce_dfuns env) (idName d)
      , Just i <- elemIndex sel (classMethods cls)
      , Just (Just m) <- listToMaybe (drop i meths)
      = varVerdict m
      -- an imported instance: the method in the dictionary function's unfolding
      | isDFunId d
      , not (nameIsLocalOrFrom (ce_mod env) (idName d))
      , DFunUnfolding { df_args = dargs } <- idUnfolding d
      , Just i <- elemIndex sel (classAllSelIds cls)
        -- the arguments of the dictionary constructor start with its type arguments
      , Just meth <- listToMaybe (drop i (filter (not . isTypeArg) dargs))
      = do let facts = f_facts (walkEvTerm sp (EvExpr meth))
                        ++ concat [ f_facts (walkEvTerm sp (EvExpr a)) | a <- args, not (isTypeArg a) ]
           firstResult =<< mapM (factVerdict env ctx) facts
      -- otherwise the whole dictionary is the dependency
      | otherwise = firstResult =<< mapM (factVerdict env ctx)
                      (f_facts (walkEvTerm sp (EvExpr (mkApps (Var d) args))))

    firstResult rs = return $ case [ r | r@(FrBad _) <- rs ] ++ [ r | r@(FrDep {}) <- rs ] of
      (r : _) -> r
      [] -> FrOk

    -- A verdict of the table is a leaf: the reason names the thing.
    fromVerdict _ VOk = return FrOk
    fromVerdict _ (VBad r h) = bad (MkPlinthBad Nothing r h sp)

-- ---------------------------------------------------------------------------
-- Types

checkType :: CheckEnv -> Type -> TcM (Maybe PlinthBad)
checkType env t0 = do
  t <- if any isFamilyTyCon (nonDetEltsUniqSet (tyConsOfType t0))
         then do fam_envs <- tcGetFamInstEnvs
                 return (reductionReducedType (normaliseType fam_envs Nominal t0))
         else return t0
  go t
  where
    go t
      | Just t' <- coreView t = go t'
      | isLiftedTypeKind t = ok
    go (TyVarTy _) = ok
    go (AppTy a b) = go a `orElseM` go b
    go t@(TyConApp tc args)
      | isClassTyCon tc = ok      -- a constraint: the dictionary is opaque
      | tc == fUNTyCon = firstBadM (map go (drop 3 args))   -- FUN m r1 r2 a b
      | isPromotedDataCon tc, isKindArg (typeKind t) = ok    -- Many, LiftedRep, ...
      | isTypeFamilyTyCon tc
      = bad (Just (culpritOf env (tyConName tc)))
            (fsLit "irreducible type family application") Nothing
      | otherwise = checkTyCon env tc `orElseM` firstBadM (map go args)
    go (ForAllTy (Bndr tv _) body) = kindOk (tyVarKind tv) `orElseM` go body
    go (FunTy _ _ a r) = go a `orElseM` go r
    go (LitTy _) = bad Nothing (fsLit "type-level literal") Nothing
    go (CastTy t _) = go t
    go (CoercionTy _) = ok

    ok = return Nothing
    bad c r h = return (Just (MkPlinthBad c r h Nothing))

-- | A kind argument that the checker ignores: multiplicities, runtime
-- representations and levities.
isKindArg :: Kind -> Bool
isKindArg k = isMultiplicityTy k || isRuntimeRepTy k || isLevityTy k

-- | Kinds other than Type (and arrows of Type) have no UPLC counterpart.
kindOk :: Kind -> TcM (Maybe PlinthBad)
kindOk k
  | isTYPEorCONSTRAINT k = return Nothing   -- Type, and the levity-polymorphic TYPE r
  | isKindArg k = return Nothing            -- a RuntimeRep, Levity or Multiplicity binder
  | Just k' <- coreView k = kindOk k'
  | FunTy _ _ a r <- k = kindOk a `orElseM` kindOk r
  | otherwise = return (Just (MkPlinthBad Nothing (fsLit "kind other than Type")
                                (Just (fsLit "poly-kinded types are not supported")) Nothing))

checkTyCon :: CheckEnv -> TyCon -> TcM (Maybe PlinthBad)
checkTyCon env tc = do
  memo <- liftIO (readIORef (ce_tycons env))
  case lookupNameEnv memo n of
    Just (Done r) -> return r
    Just InProgress -> do
      stack <- liftIO (readIORef (ce_stack env))
      case stack of
        (top : _)
          | top == tc, isNewTyCon tc
          -> bad (fsLit "recursive newtype") (Just (fsLit "use data instead"))
          | top == tc -> return Nothing
        _ -> bad (fsLit "mutually recursive data types")
                 (Just (fsLit "merge the types or break the cycle"))
    Nothing -> do
      r <- verdict
      liftIO (modifyIORef' (ce_tycons env) (\m -> extendNameEnv m n (Done r)))
      return r
  where
    n = tyConName tc
    culprit = Just (culpritOf env n)
    bad r h = return (Just (MkPlinthBad culprit r h Nothing))

    verdict = case tyConVerdict tc of
      Just VOk -> return Nothing
      Just (VBad r h) -> bad r h
      Nothing
        | tc == fUNTyCon -> return Nothing
        | isTypeSynonymTyCon tc -> return Nothing   -- expanded where it is applied
        | isClassTyCon tc -> return Nothing
        | isFamilyTyCon tc -> bad (fsLit "type family") Nothing
        | isPromotedDataCon tc -> bad (fsLit "promoted data constructor") Nothing
        | isPrimTyCon tc -> bad (fsLit "primitive type") (Just (fsLit "use Integer or a builtin type"))
        | isUnboxedTupleTyCon tc || isUnboxedSumTyCon tc -> bad (fsLit "unboxed tuple or sum") Nothing
        | isAbstractTyCon tc -> bad (fsLit "abstract type") Nothing
        | isNewTyCon tc -> inProgress (checkType env (snd (newTyConRhs tc)))
        | isAlgTyCon tc -> inProgress $
            firstBadM (map (kindOk . tyVarKind . binderVar) (tyConBinders tc))
              `orElseM` kindOk (tyConResKind tc)
              `orElseM` firstBadM (map conVerdict (tyConDataCons tc))
        | otherwise -> return Nothing

    inProgress act = do
      liftIO $ do
        modifyIORef' (ce_tycons env) (\m -> extendNameEnv m n InProgress)
        modifyIORef' (ce_stack env) (tc :)
      r <- act
      liftIO (modifyIORef' (ce_stack env) (drop 1))
      return r

    conVerdict dc
      | not (isVanillaDataCon dc)
      = return (Just (MkPlinthBad (Just (culpritOf env (dataConName dc)))
                        (fsLit "existential or GADT constructor")
                        (Just (fsLit "use a plain algebraic data type")) Nothing))
      | otherwise = firstBadM (map (checkType env . scaledThing) (dataConOrigArgTys dc))

orElseM :: Monad m => m (Maybe a) -> m (Maybe a) -> m (Maybe a)
orElseM a b = a >>= \case
  Nothing -> b
  r -> return r

firstBadM :: Monad m => [m (Maybe a)] -> m (Maybe a)
firstBadM = foldr orElseM (return Nothing)

-- ---------------------------------------------------------------------------
-- Propagation

propagate :: Module -> [Node] -> [Direct] -> IM.IntMap PlinthStatus
propagate this_mod nodes directs = loop initial
  where
    initial = IM.fromList [ (nd_id n, maybe PlinthOk PlinthBad (dr_bad d))
                          | (n, d) <- zip nodes directs ]
    deps = IM.fromList [ (nd_id n, dr_deps d) | (n, d) <- zip nodes directs ]

    loop st = case foldl step (st, False) (IM.keys st) of
      (st', True) -> loop st'
      (st', False) -> st'

    step (st, changed) i = case IM.lookup i st of
      Just PlinthOk
        | Just ds <- IM.lookup i deps
        , (bad : _) <- [ MkPlinthBad (Just (CulpritName this_mod (idName v))) (pb_reason b) (pb_hint b) sp
                       | (j, v, sp) <- ds, Just (PlinthBad b) <- [IM.lookup j st] ]
        -> (IM.insert i (PlinthBad bad) st, True)
      _ -> (st, changed)

-- ---------------------------------------------------------------------------
-- Tagging

tagBind :: (Name -> Maybe PlinthStatus) -> HsBind GhcTc -> HsBind GhcTc
tagBind status_of b = case b of
  FunBind { fun_id = L l v } -> b { fun_id = L l (tag v) }
  VarBind { var_id = v } -> b { var_id = tag v }
  PatSynBind x psb@(PSB { psb_id = L l v }) -> PatSynBind x psb { psb_id = L l (tag v) }
  XHsBindsLR ab@(AbsBinds { abs_exports = es })
    -> XHsBindsLR ab { abs_exports = [ e { abe_poly = tag (abe_poly e) } | e <- es ] }
  _ -> b
  where
    tag v = maybe v (setIdPlinthStatus v) (status_of (idName v))

-- ---------------------------------------------------------------------------
-- The gate

data GateMode = GateOff | GateWarn | GateError
  deriving Eq

gateMode :: DynFlags -> GateMode
gateMode dflags
  | gopt Opt_PlinthGateWarn dflags = GateWarn
  | not (gopt Opt_PlinthGate dflags) = GateOff
  | defer_errors = GateOff
  | otherwise = GateError
  where
    -- The plugin options defer-errors and no-plinth-gate keep the plugin's
    -- own error path. The most recent option is first in the list.
    defer_errors = latest ["defer-errors", "no-defer-errors"] == Just "defer-errors"
                || latest ["no-plinth-gate", "plinth-gate"] == Just "no-plinth-gate"
    latest opts = listToMaybe [ opt | (m, opt) <- pluginModNameOpts dflags
                                    , m == plinthPluginModuleName, opt `elem` opts ]

-- | Validate the argument of one splice. Returns False if it was rejected.
gateSplice :: CheckEnv -> NameEnv Id -> IM.IntMap PlinthStatus -> GateMode -> LHsExpr GhcTc -> TcM Bool
gateSplice env node_ids statuses mode arg@(L l _) = do
  let facts = resolveEvidence env (f_facts (walkExpr (srcSpanToRealSrcSpan (locA l)) arg))
      ctx = mkNodeCtx env facts
  results <- mapM (factVerdict env ctx) facts
  let bads = [ b | FrBad b <- results ]
          ++ [ MkPlinthBad (Just (CulpritName (ce_mod env) (idName v))) (pb_reason b) (pb_hint b) sp
             | FrDep i v sp <- results, Just (PlinthBad b) <- [IM.lookup i statuses] ]
  chains <- mapM (buildChain env node_ids statuses) bads
  -- One report per unsupported feature: several paths lead to the same
  -- leaf (a Word64 literal: the type, and fromInteger of the type).
  forM_ (dedupe chains) $ \(chain, leaf, loc) -> do
    let diag = PlinthNotValid { pd_warning = mode == GateWarn, pd_chain = chain, pd_leaf = leaf }
        loc' = case loc of
          Just sp -> RealSrcSpan sp Strict.Nothing
          Nothing -> locA l
    addDiagnosticAt loc' (mkTcRnUnknownMessage diag)
  return (null bads)
  where
    dedupe = go []
      where go _ [] = []
            go seen (c@(_, leaf, _) : cs)
              | key leaf `elem` seen = go seen cs
              | otherwise = c : go (key leaf : seen) cs
            key leaf = (pb_culprit leaf, pb_reason leaf)

-- | Follow the culprits from a Bad to the unsupported feature. Returns the
-- chain of bindings, the leaf, and the deepest location in the current
-- module.
--
-- A binding culprit carries its own status; a type culprit is checked
-- again here (the check is structural and memoised) to find what is wrong
-- inside it.
buildChain :: CheckEnv -> NameEnv Id -> IM.IntMap PlinthStatus -> PlinthBad
           -> TcM ([Link], PlinthBad, Maybe RealSrcSpan)
buildChain env node_ids statuses bad0 = go [] [] (pb_span bad0) bad0
  where
    this_mod = ce_mod env

    go visited links loc bad = case pb_culprit bad of
      Just c | c `notElem` visited -> do
        found <- lookupCulprit c
        let (m, occ) = culpritModOcc c
            home = m == this_mod
            link def = Link { lk_module = m, lk_occ = occ, lk_def = def, lk_home = home }
            visited' = c : visited
        case found of
          Just (Left st, def) -> case st of
            PlinthBad bad' ->
              go visited' (link def : links) (if home then pb_span bad' <|> loc else loc) bad'
            -- An Ok binding at the end: the problem is at the use site (no
            -- unfolding), so the binding is the last link and the leaf
            -- keeps the reason.
            PlinthOk -> finish (link def : links) bad { pb_culprit = Nothing } loc
          Just (Right tc, def) -> do
            inside <- checkTyCon env tc
            case inside of
              Just bad' | pb_culprit bad' /= Just c -> go visited' (link def : links) loc bad'
              _ -> finish links bad loc     -- the type itself is the feature
          Nothing -> finish links bad loc   -- a class, a constructor, an unknown name
      _ -> finish links bad loc

    finish links bad loc = return (reverse links, bad, loc)

    -- The status (of a binding) or the type constructor behind a culprit,
    -- with its definition span. The definition span of a name from
    -- another package is not restored on the Name, so such a link shows
    -- the unit only.
    lookupCulprit :: PlinthCulprit -> TcM (Maybe (Either PlinthStatus TyCon, Maybe RealSrcSpan))
    lookupCulprit (CulpritName _ n) = return $ do
      v <- lookupNameEnv node_ids n
      i <- lookupNameEnv (ce_binders env) n
      st <- IM.lookup i statuses
      return (Left st, srcSpanToRealSrcSpan (nameSrcSpan (idName v)))
    lookupCulprit (CulpritExt m occ) = do
      name <- lookupOrig m occ
      found <- tryTcDiscardingErrs (return Nothing) (Just <$> tcLookupGlobal name)
      return $ case found of
        Just (AnId v) | Just st <- idPlinthStatus v
          -> Just (Left st, srcSpanToRealSrcSpan (nameSrcSpan (idName v)))
        Just (ATyCon tc)
          -> Just (Right tc, srcSpanToRealSrcSpan (nameSrcSpan (tyConName tc)))
        _ -> Nothing



-- | Dynamically lookup up values from modules and loading them.
module GHC.Runtime.Loader (
        initializePlugins, initializeSessionPlugins,
        -- * Loading plugins
        loadFrontendPlugin,

        -- * Force loading information
        forceLoadModuleInterfaces,
        forceLoadNameModuleInterface,
        forceLoadTyCon,

        -- * Finding names
        lookupRdrNameInModuleForPlugins,

        -- * Loading values
        getValueSafely,
        getHValueSafely,
        lessUnsafeCoerce
    ) where

import GHC.Prelude
import GHC.Data.FastString

import GHC.Driver.Session
import GHC.Driver.Ppr
import GHC.Driver.Hooks
import GHC.Driver.Plugins
import GHC.Driver.Plugins.External

import GHC.Linker.Loader       ( loadModule, loadName )
import GHC.Runtime.Interpreter ( wormhole )
import GHC.Runtime.Interpreter.Types

import GHC.Tc.Utils.Monad      ( initTcInteractive, initIfaceTcRn )
import GHC.Iface.Load          ( loadPluginInterface, cannotFindModule )
import GHC.Rename.Names ( gresFromAvails )
import GHC.Builtin.Names ( pluginTyConName, frontendPluginTyConName )

import GHC.Driver.Env
import GHCi.RemoteTypes     ( HValue )
import GHC.Core.Type        ( Type, mkTyConTy )
import GHC.Core.TyCo.Compare( eqType )
import GHC.Core.TyCon       ( TyCon )

import GHC.Types.SrcLoc        ( noSrcSpan )
import GHC.Types.Name    ( Name, nameModule_maybe )
import GHC.Types.Id      ( idType )
import GHC.Types.TyThing
import GHC.Types.Name.Occurrence ( OccName, mkVarOccFS )
import GHC.Types.Name.Reader   ( RdrName, ImportSpec(..), ImpDeclSpec(..)
                               , ImpItemSpec(..), mkGlobalRdrEnv, lookupGRE_RdrName
                               , greMangledName, mkRdrQual )

import GHC.Unit.Finder         ( findPluginModule, FindResult(..) )
import GHC.Driver.Config.Finder ( initFinderOpts )
import GHC.Unit.Module   ( Module, ModuleName )
import GHC.Unit.Module.ModIface
import GHC.Unit.Env

import GHC.Utils.Panic
import GHC.Utils.Logger
import GHC.Utils.Error
import GHC.Utils.Outputable
import GHC.Utils.Exception

import Control.Monad     ( unless )
import Data.Maybe        ( mapMaybe )
import Unsafe.Coerce     ( unsafeCoerce )
import GHC.Linker.Types
import GHC.Types.Unique.DFM
import Data.List (unzip4)
import GHC.Driver.Monad

-- | Initialise plugins specified by the current DynFlags and update the session.
initializeSessionPlugins :: GhcMonad m => m ()
initializeSessionPlugins = getSession >>= liftIO . initializePlugins >>= setSession

-- | Loads the plugins specified in the pluginModNames field of the dynamic
-- flags. Should be called after command line arguments are parsed, but before
-- actual compilation starts. Idempotent operation. Should be re-called if
-- pluginModNames or pluginModNameOpts changes.
initializePlugins :: HscEnv -> IO HscEnv
initializePlugins hsc_env
    -- check that plugin specifications didn't change

    -- static plugins: see Note [Per-module options for static plugins]
  | all static_args_unchanged (staticPlugins (hsc_plugins hsc_env))

    -- dynamic plugins
  , loaded_plugins <- loadedPlugins (hsc_plugins hsc_env)
  , map lpModuleName loaded_plugins == dynPluginModNamesToLoad hsc_env
  , all same_args loaded_plugins

    -- external plugins
  , external_plugins <- externalPlugins (hsc_plugins hsc_env)
  , check_external_plugins external_plugins (externalPluginSpecs dflags)

  = return hsc_env -- no change, no need to reload plugins

  | otherwise
  = do (loaded_plugins, links, pkgs) <- loadPlugins hsc_env
       external_plugins <- loadExternalPlugins (externalPluginSpecs dflags)
       let plugins' = (hsc_plugins hsc_env) { staticPlugins    = map refreshStaticArgs (staticPlugins (hsc_plugins hsc_env))
                                            , externalPlugins  = external_plugins
                                            , loadedPlugins    = loaded_plugins
                                            , loadedPluginDeps = (links, pkgs)
                                            }
       let hsc_env' = hsc_env { hsc_plugins = plugins' }
       withPlugins (hsc_plugins hsc_env') driverPlugin hsc_env'
  where
    dflags = hsc_dflags hsc_env
    -- dynamic plugins
    plugin_args = pluginModNameOpts dflags
    same_args p = paArguments (lpPlugin p) == argumentsForPlugin (lpModuleName p) plugin_args
    argumentsForPlugin mn = map snd . filter ((== mn) . fst)
    -- static plugins: see Note [Per-module options for static plugins]
    refreshStaticArgs sp = case spModuleName sp of
      Nothing -> sp
      Just mn -> sp { spPlugin = (spPlugin sp) { paArguments = argumentsForPlugin mn plugin_args } }
    static_args_unchanged sp = case spModuleName sp of
      Nothing -> True
      Just mn -> paArguments (spPlugin sp) == argumentsForPlugin mn plugin_args
    -- external plugins
    check_external_plugin p spec = and
      [ epUnit                p  == esp_unit_id spec
      , epModule              p  == esp_module spec
      , paArguments (epPlugin p) == esp_args spec
      ]
    check_external_plugins eps specs = case (eps,specs) of
      ([]  , [])  -> True
      (_   , [])  -> False -- some external plugin removed
      ([]  , _ )  -> False -- some external plugin added
      (p:ps,s:ss) -> check_external_plugin p s && check_external_plugins ps ss

loadPlugins :: HscEnv -> IO ([LoadedPlugin], [Linkable], PkgsLoaded)
loadPlugins hsc_env
  = do { unless (null to_load) $
           checkExternalInterpreter hsc_env
       ; plugins_with_deps <- mapM loadPlugin to_load
       ; let (plugins, ifaces, links, pkgs) = unzip4 plugins_with_deps
       ; return (zipWith attachOptions to_load (zip plugins ifaces), concat links, foldl' plusUDFM emptyUDFM pkgs)
       }
  where
    dflags  = hsc_dflags hsc_env
    to_load = dynPluginModNamesToLoad hsc_env

    attachOptions mod_nm (plug, mod) =
        LoadedPlugin (PluginWithArgs plug (reverse options)) mod
      where
        options = [ option | (opt_mod_nm, option) <- pluginModNameOpts dflags
                            , opt_mod_nm == mod_nm ]
    loadPlugin = loadPlugin' (mkVarOccFS (fsLit "plugin")) pluginTyConName hsc_env

-- Note [Static plugins shadow -fplugin]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- A host program (e.g. uplc-ghc / Plinth) can compile a plugin into the
-- GHC executable itself by registering it as a 'StaticPlugin'. Source
-- modules that request the plugin with -fplugin=M should then NOT
-- trigger a dynamic load of module M -- the static plugin already
-- provides it. Worse, with GHC's external interpreter enabled, any
-- non-empty dynamic plugin list aborts with "Plugins require
-- -fno-external-interpreter" (#14335), which breaks perfectly valid
-- user code targeting the statically linked plugin.
--
-- 'dynPluginModNamesToLoad' filters out any name already claimed by a
-- 'StaticPlugin' (matched via its 'spModuleName'). The remaining
-- modules are the ones that must actually be loaded from disk.
--
-- 'pluginModNameOpts' is left untouched: -fplugin-opt arguments for
-- the shadowed module reach the static plugin via the per-module
-- args refresh in 'initializePlugins'. See Note [Per-module options
-- for static plugins].

-- Note [Per-module options for static plugins]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- A 'StaticPlugin' is registered once (e.g. in the host program's
-- main, before compilation begins) with a fixed set of
-- 'paArguments'. That registration only sees the global session
-- DynFlags, so per-module pragmas like
--    {-# OPTIONS_GHC -fplugin-opt M:k=v #-}
-- which only land in the per-module DynFlags' 'pluginModNameOpts',
-- would be silently ignored without a refresh.
--
-- 'initializePlugins' runs at the start of every per-module
-- compilation (see callers in GHC.Driver.Pipeline). On each call we
-- recompute each static plugin's args from the current
-- 'pluginModNameOpts', filtered by the plugin's 'spModuleName'. If
-- the args differ from what the static plugin currently holds, we
-- treat the change like any other plugin reconfiguration and take
-- the rebuild branch so 'driverPlugin' gets a chance to react.
--
-- Static plugins registered without an 'spModuleName' (e.g. haddock)
-- have no module name to filter by, so their args are not rewritten:
-- they keep whatever the registrar set, matching pre-existing
-- behaviour.
dynPluginModNamesToLoad :: HscEnv -> [ModuleName]
dynPluginModNamesToLoad hsc_env =
    filter (not . claimedByStatic) (reverse (pluginModNames (hsc_dflags hsc_env)))
  where
    static_names = mapMaybe spModuleName (staticPlugins (hsc_plugins hsc_env))
    claimedByStatic nm = nm `elem` static_names


loadFrontendPlugin :: HscEnv -> ModuleName -> IO (FrontendPlugin, [Linkable], PkgsLoaded)
loadFrontendPlugin hsc_env mod_name = do
    checkExternalInterpreter hsc_env
    (plugin, _iface, links, pkgs)
      <- loadPlugin' (mkVarOccFS (fsLit "frontendPlugin")) frontendPluginTyConName
           hsc_env mod_name
    return (plugin, links, pkgs)

-- #14335
checkExternalInterpreter :: HscEnv -> IO ()
checkExternalInterpreter hsc_env = case interpInstance <$> hsc_interp hsc_env of
  Just (ExternalInterp {})
    -> throwIO (InstallationError "Plugins require -fno-external-interpreter")
  _ -> pure ()

loadPlugin' :: OccName -> Name -> HscEnv -> ModuleName -> IO (a, ModIface, [Linkable], PkgsLoaded)
loadPlugin' occ_name plugin_name hsc_env mod_name
  = do { let plugin_rdr_name = mkRdrQual mod_name occ_name
             dflags = hsc_dflags hsc_env
       ; mb_name <- lookupRdrNameInModuleForPlugins hsc_env mod_name
                        plugin_rdr_name
       ; case mb_name of {
            Nothing ->
                throwGhcExceptionIO (CmdLineError $ showSDoc dflags $ hsep
                          [ text "The module", ppr mod_name
                          , text "did not export the plugin name"
                          , ppr plugin_rdr_name ]) ;
            Just (name, mod_iface) ->

     do { plugin_tycon <- forceLoadTyCon hsc_env plugin_name
        ; eith_plugin <- getValueSafely hsc_env name (mkTyConTy plugin_tycon)
        ; case eith_plugin of
            Left actual_type ->
                throwGhcExceptionIO (CmdLineError $
                    showSDocForUser dflags (ue_units (hsc_unit_env hsc_env))
                      alwaysQualify $ hsep
                          [ text "The value", ppr name
                          , text "with type", ppr actual_type
                          , text "did not have the type"
                          , text "GHC.Plugins.Plugin"
                          , text "as required"])
            Right (plugin, links, pkgs) -> return (plugin, mod_iface, links, pkgs) } } }


-- | Force the interfaces for the given modules to be loaded. The 'SDoc' parameter is used
-- for debugging (@-ddump-if-trace@) only: it is shown as the reason why the module is being loaded.
forceLoadModuleInterfaces :: HscEnv -> SDoc -> [Module] -> IO ()
forceLoadModuleInterfaces hsc_env doc modules
    = (initTcInteractive hsc_env $
       initIfaceTcRn $
       mapM_ (loadPluginInterface doc) modules)
      >> return ()

-- | Force the interface for the module containing the name to be loaded. The 'SDoc' parameter is used
-- for debugging (@-ddump-if-trace@) only: it is shown as the reason why the module is being loaded.
forceLoadNameModuleInterface :: HscEnv -> SDoc -> Name -> IO ()
forceLoadNameModuleInterface hsc_env reason name = do
    let name_modules = mapMaybe nameModule_maybe [name]
    forceLoadModuleInterfaces hsc_env reason name_modules

-- | Load the 'TyCon' associated with the given name, come hell or high water. Fails if:
--
-- * The interface could not be loaded
-- * The name is not that of a 'TyCon'
-- * The name did not exist in the loaded module
forceLoadTyCon :: HscEnv -> Name -> IO TyCon
forceLoadTyCon hsc_env con_name = do
    forceLoadNameModuleInterface hsc_env (text "contains a name used in an invocation of loadTyConTy") con_name

    mb_con_thing <- lookupType hsc_env con_name
    case mb_con_thing of
        Nothing -> throwCmdLineErrorS dflags $ missingTyThingError con_name
        Just (ATyCon tycon) -> return tycon
        Just con_thing -> throwCmdLineErrorS dflags $ wrongTyThingError con_name con_thing
  where dflags = hsc_dflags hsc_env

-- | Loads the value corresponding to a 'Name' if that value has the given 'Type'. This only provides limited safety
-- in that it is up to the user to ensure that that type corresponds to the type you try to use the return value at!
--
-- If the value found was not of the correct type, returns @Left <actual_type>@. Any other condition results in an exception:
--
-- * If we could not load the names module
-- * If the thing being loaded is not a value
-- * If the Name does not exist in the module
-- * If the link failed

getValueSafely :: HscEnv -> Name -> Type -> IO (Either Type (a, [Linkable], PkgsLoaded))
getValueSafely hsc_env val_name expected_type = do
  eith_hval <- case getValueSafelyHook hooks of
    Nothing -> getHValueSafely interp hsc_env val_name expected_type
    Just h  -> h                      hsc_env val_name expected_type
  case eith_hval of
    Left actual_type -> return (Left actual_type)
    Right (hval, links, pkgs) -> do
      value <- lessUnsafeCoerce logger "getValueSafely" hval
      return (Right (value, links, pkgs))
  where
    interp = hscInterp hsc_env
    logger = hsc_logger hsc_env
    hooks  = hsc_hooks hsc_env

getHValueSafely :: Interp -> HscEnv -> Name -> Type -> IO (Either Type (HValue, [Linkable], PkgsLoaded))
getHValueSafely interp hsc_env val_name expected_type = do
    forceLoadNameModuleInterface hsc_env (text "contains a name used in an invocation of getHValueSafely") val_name
    -- Now look up the names for the value and type constructor in the type environment
    mb_val_thing <- lookupType hsc_env val_name
    case mb_val_thing of
        Nothing -> throwCmdLineErrorS dflags $ missingTyThingError val_name
        Just (AnId id) -> do
            -- Check the value type in the interface against the type recovered from the type constructor
            -- before finally casting the value to the type we assume corresponds to that constructor
            if expected_type `eqType` idType id
             then do
                -- Link in the module that contains the value, if it has such a module
                case nameModule_maybe val_name of
                    Just mod -> do loadModule interp hsc_env mod
                                   return ()
                    Nothing ->  return ()
                -- Find the value that we just linked in and cast it given that we have proved it's type
                hval <- do
                  (v, links, pkgs) <- loadName interp hsc_env val_name
                  hv <- wormhole interp v
                  return (hv, links, pkgs)
                return (Right hval)
             else return (Left (idType id))
        Just val_thing -> throwCmdLineErrorS dflags $ wrongTyThingError val_name val_thing
   where dflags = hsc_dflags hsc_env

-- | Coerce a value as usual, but:
--
-- 1) Evaluate it immediately to get a segfault early if the coercion was wrong
--
-- 2) Wrap it in some debug messages at verbosity 3 or higher so we can see what happened
--    if it /does/ segfault
lessUnsafeCoerce :: Logger -> String -> a -> IO b
lessUnsafeCoerce logger context what = do
    debugTraceMsg logger 3 $
        (text "Coercing a value in") <+> (text context) <> (text "...")
    output <- evaluate (unsafeCoerce what)
    debugTraceMsg logger 3 (text "Successfully evaluated coercion")
    return output


-- | Finds the 'Name' corresponding to the given 'RdrName' in the
-- context of the 'ModuleName'. Returns @Nothing@ if no such 'Name'
-- could be found. Any other condition results in an exception:
--
-- * If the module could not be found
-- * If we could not determine the imports of the module
--
-- Can only be used for looking up names while loading plugins (and is
-- *not* suitable for use within plugins).  The interface file is
-- loaded very partially: just enough that it can be used, without its
-- rules and instances affecting (and being linked from!) the module
-- being compiled.  This was introduced by 57d6798.
--
-- Need the module as well to record information in the interface file
lookupRdrNameInModuleForPlugins :: HscEnv -> ModuleName -> RdrName
                                -> IO (Maybe (Name, ModIface))
lookupRdrNameInModuleForPlugins hsc_env mod_name rdr_name = do
    let dflags     = hsc_dflags hsc_env
    let fopts      = initFinderOpts dflags
    let fc         = hsc_FC hsc_env
    let unit_env   = hsc_unit_env hsc_env
    let unit_state = ue_units unit_env
    let mhome_unit = hsc_home_unit_maybe hsc_env
    -- First find the unit the module resides in by searching exposed units and home modules
    found_module <- findPluginModule fc fopts unit_state mhome_unit mod_name
    case found_module of
        Found _ mod -> do
            -- Find the exports of the module
            (_, mb_iface) <- initTcInteractive hsc_env $
                             initIfaceTcRn $
                             loadPluginInterface doc mod
            case mb_iface of
                Just iface -> do
                    -- Try and find the required name in the exports
                    let decl_spec = ImpDeclSpec { is_mod = mod_name, is_as = mod_name
                                                , is_qual = False, is_dloc = noSrcSpan }
                        imp_spec = ImpSpec decl_spec ImpAll
                        env = mkGlobalRdrEnv (gresFromAvails (Just imp_spec) (mi_exports iface))
                    case lookupGRE_RdrName rdr_name env of
                        [gre] -> return (Just (greMangledName gre, iface))
                        []    -> return Nothing
                        _     -> panic "lookupRdrNameInModule"

                Nothing -> throwCmdLineErrorS dflags $ hsep [text "Could not determine the exports of the module", ppr mod_name]
        err -> throwCmdLineErrorS dflags $ cannotFindModule hsc_env mod_name err
  where
    doc = text "contains a name used in an invocation of lookupRdrNameInModule"

wrongTyThingError :: Name -> TyThing -> SDoc
wrongTyThingError name got_thing = hsep [text "The name", ppr name, text "is not that of a value but rather a", pprTyThingCategory got_thing]

missingTyThingError :: Name -> SDoc
missingTyThingError name = hsep [text "The name", ppr name, text "is not in the type environment: are you sure it exists?"]

throwCmdLineErrorS :: DynFlags -> SDoc -> IO a
throwCmdLineErrorS dflags = throwCmdLineError . showSDoc dflags

throwCmdLineError :: String -> IO a
throwCmdLineError = throwGhcExceptionIO . CmdLineError

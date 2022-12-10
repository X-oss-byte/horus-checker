{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
module Horus.Global.Runner (interpret, run, Env (..)) where

import Control.Monad.Except (ExceptT, MonadError (..), liftEither, runExceptT, throwError)
import Control.Monad.Free.Church (iterM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Control.Monad.Trans (MonadTrans (..))
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Text (Text, unpack)
import Data.Text.IO qualified as Text (writeFile)
import System.Directory (createDirectoryIfMissing)
import System.FilePath.Posix (takeDirectory)
import Text.Pretty.Simple (pPrintString)

import Horus.CFGBuild.Runner qualified as CFGBuild (interpret, runImpl)
import Horus.CairoSemantics.Runner qualified as CairoSemantics (run)
import Horus.ContractInfo (ContractInfo (..))
import Horus.Global (Config (..), GlobalF (..), GlobalL (..), Env (..))
import Horus.Module.Runner qualified as Module (run)
import Horus.Preprocessor.Runner qualified as Preprocessor (run)

type Impl = ReaderT Env (ExceptT Text IO) -- TODO replace ExceptT with exceptions

interpret :: GlobalL a -> Impl a
interpret = iterM exec . runGlobalL
 where
  exec :: GlobalF (Impl a) -> Impl a
  exec (RunCFGBuildL builder cont) = do
    ci <- asks e_contractInfo
    liftEither (CFGBuild.runImpl ci (CFGBuild.interpret builder)) >>= cont
  exec (RunCairoSemanticsL builder cont) = do
    ci <- asks e_contractInfo
    liftEither (CairoSemantics.run ci builder) >>= cont
  exec (RunModuleL builder cont) = liftEither (Module.run builder) >>= cont
  exec (RunPreprocessorL penv preprocessor cont) = do
    mPreprocessed <- lift (Preprocessor.run penv preprocessor)
    liftEither mPreprocessed >>= cont
  exec (GetCallee inst cont) = do
    ci <- asks e_contractInfo
    ci_getCallee ci inst >>= cont
  exec (GetConfig cont) = asks e_config >>= liftIO . readIORef >>= cont
  exec (GetFuncSpec name cont) = do
    ci <- asks e_contractInfo
    cont (ci_getFuncSpec ci name)
  exec (GetIdentifiers cont) = asks (ci_identifiers . e_contractInfo) >>= cont
  exec (GetSources cont) = asks (ci_sources . e_contractInfo) >>= cont
  exec (SetConfig conf cont) = do
    configRef <- asks e_config
    liftIO (writeIORef configRef conf)
    cont
  exec (PutStrLn' what cont) = pPrintString (unpack what) >> cont
  exec (WriteFile' file text cont) = liftIO (createAndWriteFile file text) >> cont
  exec (Throw t) = throwError t
  exec (Catch m handler cont) = catchError (interpret m) (interpret . handler) >>= cont

run :: Env -> GlobalL a -> IO (Either Text a)
run env = runExceptT . flip runReaderT env . interpret

createAndWriteFile :: FilePath -> Text -> IO ()
createAndWriteFile file content = do
  createDirectoryIfMissing True $ takeDirectory file
  Text.writeFile file content

{-# LANGUAGE LambdaCase #-}

module Horus.Arguments (Arguments (..), argParser, fileArgument) where

import Control.Monad.Except (throwError)
import Data.Text (Text, unpack)
import Options.Applicative

import Horus.Global (Config (..))
import Horus.Preprocessor.Solvers (Solver, cvc5, mathsat, z3)

data Arguments = Arguments
  { arg_fileName :: FilePath
  , arg_config :: Config
  }

fileArgument :: Text
fileArgument = "COMPILED_FILE"

solverReader :: ReadM Solver
solverReader = eitherReader $ \case
  "z3" -> pure z3
  "cvc5" -> pure cvc5
  "mathsat" -> pure mathsat
  solver -> throwError ("Incorrect solver: " <> solver)

argParser :: Parser Arguments
argParser =
  Arguments
    <$> strArgument
      (metavar (unpack fileArgument))
    <*> configParser

configParser :: Parser Config
configParser =
  Config
    <$> switch
      ( long "verbose"
          <> short 'v'
          <> help "If the flag is set all the intermediate steps are printed out."
      )
    <*> switch
      ( long "print-models"
          <> showDefault
          <> help "Print models for SAT results."
      )
    <*> option
      solverReader
      ( long "solver"
          <> short 's'
          <> metavar "SOLVER"
          <> value z3
          <> showDefault
          <> help "Solver to check the resulting smt queries."
      )
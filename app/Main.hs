module Main (main) where

import Control.Applicative ((<**>))
import Control.Monad (unless, when)
import Control.Monad.Except (ExceptT, liftEither, runExceptT)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON, Result (..), eitherDecodeFileStrict, fromJSON)
import Data.Aeson.Extra.Merge (lodashMerge)
import Data.Foldable (for_)
import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TextIO (putStrLn)
import Data.Version (Version, makeVersion, parseVersion, showVersion)
import Lens.Micro ((%~), (<&>))
import Options.Applicative
  ( execParser
  , fullDesc
  , header
  , helper
  , info
  , progDescDoc
  )
import Options.Applicative.Help.Pretty (text)
import Paths_horus_check (version)
import Text.ParserCombinators.ReadP (readP_to_S)

import Horus.Arguments (Arguments (..), argParser, fileArgument, specFileArgument)
import Horus.ContractDefinition (ContractDefinition, cdSpecs, cd_version)
import Horus.ContractInfo (mkContractInfo)
import Horus.Global (HorusResult (..), SolvingInfo (..), cfg_version, solveContract)
import Horus.Global.Runner qualified as Global (Env (..), run)
import Horus.SW.Std (stdSpecs)
import Horus.Util (tShow)

type EIO = ExceptT Text IO

hint :: Text
hint =
  "A result of 'Unknown' indicates that Horus was not able to prove that the \n\
  \specification holds *nor* find a counterxample. For functions yielding\n\
  \'Unknown', try increasing the solver timeout by passing '-t <milliseconds>'.\n\
  \The default is 2000ms.\n\
  \\n\
  \The timeout is per-SMT-query, which means that for a compiled contract\n\
  \containing 7 functions that requires a total of 11 queries, a 5000ms timeout\n\
  \implies a maximum running time of 55 seconds. Each function will give rise to\n\
  \at least one query, and in general, queries are in 1-1 correspondence with \n\
  \branches of control flow (so a function with a single if-then-else will require\n\
  \2 queries).\n\
  \\n\
  \Example:\n\
  \  $ horus-check -s cvc5 -t 5000 a.json"

issuesMsg :: Text
issuesMsg =
  "Horus is currently in the *alpha* stage. Please be aware of the\n\
  \known issues: https://github.com/NethermindEth/horus-checker/issues\n"

compatibleHorusCompileVersionLower :: Version
compatibleHorusCompileVersionLower = makeVersion [0, 0, 6, 8]
compatibleHorusCompileVersionHigher :: Version
compatibleHorusCompileVersionHigher = makeVersion [0, 0, 7]

{- | The main entrypoint of everything that happens in our monad stack.
 The contract is a 1-1 representation of the data in the compiled JSON file.
 The contract is then used to create a 'ContractInfo' which is a more
 convenient representation of the contract.
 We run `solveContract`, which is the entrypoint into the *rest* of the
 program, and gather the results for pretty-printing.
-}
main' :: Arguments -> FilePath -> FilePath -> EIO ()
main' Arguments{..} filename specFileName = do
  contract <- eioDecodeFileStrict filename specFileName <&> cdSpecs %~ (<> stdSpecs)
  guardVersion contract
  contractInfo <- mkContractInfo contract
  configRef <- liftIO (newIORef arg_config)
  let env = Global.Env{e_config = configRef, e_contractInfo = contractInfo}
  infos <- liftIO (Global.run env solveContract) >>= liftEither
  for_ infos $ \si -> liftIO $ do
    TextIO.putStrLn (ppSolvingInfo si)
  let unknowns = [res | res@(Timeout{}) <- map si_result infos]
  unless (null unknowns) $ liftIO (TextIO.putStrLn hint')
 where
  hint' = "\ESC[33m" <> (T.strip . T.unlines . map ("hint: " <>) . T.lines) hint <> "\ESC[0m"
  guardVersion :: ContractDefinition -> EIO ()
  guardVersion cd = do
    compilerVersion <- case [ x
                            | x@(_, lst) <- readP_to_S parseVersion (cd_version cd)
                            , null lst
                            ] of
      [(v, [])] -> pure v
      _ -> fail $ "Wrong version format: " <> cd_version cd
    when
      ( compilerVersion < compatibleHorusCompileVersionLower
          || compilerVersion >= compatibleHorusCompileVersionHigher
      )
      . fail
      . concat
      $ [ "The *.json on input has been compiled with an incompatible version of Horus-compile.\nExpected: "
        , ">="
        , showVersion compatibleHorusCompileVersionLower
        , ", <"
        , showVersion compatibleHorusCompileVersionHigher
        , " but got: "
        , showVersion compilerVersion
        ]

eioDecodeFileStrict :: FromJSON a => FilePath -> FilePath -> EIO a
eioDecodeFileStrict contractFile specFile = do
  mbContract <- liftIO (eitherDecodeFileStrict contractFile)
  mbSpecs <- liftIO (eitherDecodeFileStrict specFile)
  case (mbContract, mbSpecs) of
    (Left err, _) -> fail ("Malformed contract *.json. Cause: " ++ err)
    (_, Left err) -> fail ("Malformed specification *.json. Cause: " ++ err)
    (Right contract, Right specifications) -> do
      let mbRes = fromJSON $ lodashMerge contract specifications
      case mbRes of
        Error err -> fail ("Malformed contract *.json. Cause: " ++ err)
        Success res -> pure res

ppSolvingInfo :: SolvingInfo -> Text
ppSolvingInfo SolvingInfo{..} =
  si_moduleName <> inlinedIndicator <> "\n" <> tShow si_result <> "\n"
 where
  inlinedIndicator = if si_inlinable then " [inlined]" else ""

{- | Main entrypoint of the program.
 Cases
 =====
 1. No arguments are passed. In this case, we print the help message.
 2. The `--version` flag is passed. In this case, we print the version number.
 3. No file is passed. In this case, we print an error.
 4. A file is passed. In this case, we run `main'`.
-}
main :: IO ()
main = do
  TextIO.putStrLn issuesMsg'
  arguments <- execParser opts
  if cfg_version (arg_config arguments)
    then
      putStrLn . concat $
        [ "Horus version: "
        , showVersion version
        , "\nHorus-compile (required): "
        , ">="
        , showVersion compatibleHorusCompileVersionLower
        , ", <"
        , showVersion compatibleHorusCompileVersionHigher
        ]
    else case (arg_fileName arguments, arg_specFile arguments) of
      (Nothing, _) -> putStrLn "Missing compiled JSON file. Use --help for more information."
      (_, Nothing) -> putStrLn "Missing specification JSON file. Use --help for more information."
      (Just filename, Just specFileName) -> do
        runExceptT (main' arguments filename specFileName) >>= either (fail . T.unpack) pure
 where
  issuesMsg' =
    "\ESC[33m" <> (T.strip . T.unlines . map ("Warning: " <>) . T.lines) issuesMsg <> "\ESC[0m\n"
  opts =
    info
      (argParser <**> helper)
      ( fullDesc
          <> progDescDoc
            ( Just $
                text "Verifies "
                  <> text (T.unpack fileArgument)
                  <> text " (a JSON contract compiled with horus-compile) with the specification file "
                  <> text (T.unpack specFileArgument)
                  <> text " provided by horus-compile \n\n"
                  <> text "Example using solver cvc5 (default):\n"
                  <> text "  $ horus-check a.json spec.json\n\n"
                  <> text "Example using solver mathsat:\n"
                  <> text "  $ horus-check -s mathsat a.json spec.json\n\n"
                  <> text "Example using solvers z3, mathsat:\n"
                  <> text "  $ horus-check -s z3 -s mathsat a.json spec.json\n"
            )
          <> header "horus-check: an SMT-based checker for StarkNet contracts"
      )

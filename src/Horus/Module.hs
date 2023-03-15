module Horus.Module
  ( Module (..)
  , ModuleL (..)
  , ModuleF (..)
  , Error (..)
  , apEqualsFp
  , gatherModules
  , getModuleNameParts
  , isPreChecking
  , dropMain
  )
where

import Control.Applicative ((<|>))
import Control.Monad (unless)
import Control.Monad.Except (MonadError (..))
import Control.Monad.Free.Church (F, liftF)
import Data.Foldable (for_, traverse_)
import Data.List.NonEmpty (NonEmpty)
import Data.Map (Map)
import Data.Map qualified as Map (elems, empty, insert, map, null, toList)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text (concat, intercalate)
import Lens.Micro (ix, (^.))
import Text.Printf (printf)

import Horus.CFGBuild (ArcCondition (..), Label (unLabel), Vertex (..))
import Horus.CFGBuild.Runner (CFG (..), verticesLabelledBy)
import Horus.CallStack (CallStack, callerPcOfCallEntry, digestOfCallStack, initialWithFunc, pop, push, stackTrace, top)
import Horus.ContractInfo (pcToFun)
import Horus.Expr (Expr, Ty (..), (.&&), (.==))
import Horus.Expr qualified as Expr (and)
import Horus.Expr.SMT (pprExpr)
import Horus.Expr.Vars (ap, fp)
import Horus.FunctionAnalysis (FInfo, FuncOp (ArcCall, ArcRet), ScopedFunction (sf_scopedName), isRetArc, sizeOfCall)
import Horus.Instruction (LabeledInst, uncheckedCallDestination)
import Horus.Label (moveLabel)
import Horus.Program (Identifiers)
import Horus.SW.FuncSpec (FuncSpec (..))
import Horus.SW.Identifier (Function (..), getFunctionPc, getLabelPc)
import Horus.SW.ScopedName (ScopedName (..), toText)

data Module = Module
  { m_spec :: FuncSpec
  , m_prog :: [LabeledInst]
  , m_jnzOracle :: Map (NonEmpty Label, Label) Bool
  , m_calledF :: Label
  , m_lastPc :: (CallStack, Label)
  , m_preCheckedFuncAndCallStack :: Maybe (CallStack, ScopedFunction)
  }
  deriving stock (Show)

apEqualsFp :: Expr TBool
apEqualsFp = ap .== fp

isPreChecking :: Module -> Bool
isPreChecking = isJust . m_preCheckedFuncAndCallStack

beginOfModule :: [LabeledInst] -> Maybe Label
beginOfModule [] = Nothing
beginOfModule ((lbl, _) : _) = Just lbl

labelNamesOfPc :: Identifiers -> Label -> [ScopedName]
labelNamesOfPc idents lblpc =
  [ name
  | (name, ident) <- Map.toList idents
  , Just pc <- [getFunctionPc ident <|> getLabelPc ident]
  , pc == lblpc
  ]

-- | Remove the `__main__` prefix from top-level function names.
dropMain :: ScopedName -> ScopedName
dropMain (ScopedName ("__main__" : xs)) = ScopedName xs
dropMain name = name

{- | Summarize a list of labels for a function.

 If you have `__main__.foo.bar` on the same PC* as `__main__.foo.baz`, you
 get a string that tells you you're in `foo` scope for `bar | baz`.

 If you get more than one scope (possibly, this cannot occur in Cairo), for
 example, `__main__.foo.bar` and `__main__.FOO.baz` you get a summarization
 of the scopes `fooFOO` and `bar|baz`.
-}
summarizeLabels :: [Text] -> Text
summarizeLabels labels =
  let prettyLabels = Text.intercalate "|" labels
   in if length labels == 1
        then prettyLabels
        else Text.concat ["{", prettyLabels, "}"]

commonPrefix :: (Eq e) => [e] -> [e] -> [e]
commonPrefix _ [] = []
commonPrefix [] _ = []
commonPrefix (x : xs) (y : ys)
  | x == y = x : commonPrefix xs ys
  | otherwise = []

{- | For labels whose names are prefixed by the scope specifier equivalent to the
 scope of the function they are declared in, do not replicate this scope
 information in their name.

 We do this by computing the longest common prefix, dropping it from all the
 names, and then adding the prefix itself as a new name.
-}
sansCommonAncestor :: [[Text]] -> [[Text]]
sansCommonAncestor xss = prefix : remainders
 where
  prefix = foldl1 commonPrefix xss
  remainders = map (drop (length prefix)) xss

{- | Returns the function name parts, in particular the fully qualified
 function name and the label summary.

 We take as arguments a list of scoped names, and a boolean flag indicating
 whether the list of scoped names belongs to a function or a *floating label*
 (as distinct from a function label).

 A floating label is, for example, `add:` in the snippet below, which is
 taken from the `func_multiple_ret.cairo` test file at revision 89ddeb2:

 ```cairo
 func succpred(m) -> (res: felt) {
     ...
     add:
     [ap] = [fp - 3] - 1, ap++;
     ...
 }
 ```
 In particular, `add` is not a function name. A function name itself is, of
 course, a label. But it is not a *floating label*, as defined above.

 Note: we say "fully qualified", but we remove the `__main__` prefix from
 top-level function names, if it exists.
-}
normalizedName :: [ScopedName] -> Bool -> (Text, Text)
normalizedName scopedNames isFloatingLabel = (Text.concat scopes, labelsSummary)
 where
  -- Extract list of scopes from each ScopedName, dropping `__main__`.
  names = filter (not . null) $ sansCommonAncestor $ map (sn_path . dropMain) scopedNames
  -- If we have a floating label, we need to drop the last scope, because it is
  -- the label name itself.
  scopes = map (Text.intercalate ".") (if isFloatingLabel then map init names else names)
  -- This will almost always just be the name of the single label.
  labelsSummary = if isFloatingLabel then summarizeLabels (map last names) else ""

descrOfBool :: Bool -> Text
descrOfBool True = "1"
descrOfBool False = "2"

descrOfOracle :: Map (NonEmpty Label, Label) Bool -> Text
descrOfOracle oracle =
  if Map.null oracle
    then ""
    else (<>) ":::" . Text.concat . map descrOfBool . Map.elems $ oracle

{- | Return a quadruple of the function name, the label summary, the oracle and
    precondition check suffix (indicates, for precondition-checking modules,
    which function's precondition is being checked).

 The oracle is a string of `1` and `2` characters, representing a path
 through the control flow graph of the function. For example, if we have a
 function

 ```cairo
 func f(x : felt) -> felt {
     if (x == 0) {
         return 0;
     } else {
         return 1;
     }
 }
 ```

 then the branch where we return 0 is usually represented by `1` (since the
 predicate `x == 0` is True), and the branch where we return 1 is represented
 by `2`.

 Nested control flow results in multiple `1` or `2` characters.

 See `normalizedName` for the definition of a floating label. Here, the label
 is floating if it is not a function declaration (i.e. equal to `calledF`),
 since these are the only two types of labels we may encounter.

 Note: while we do have the name of the called function in the `Module` type,
 it does not contain the rest of the labels.
-}
getModuleNameParts :: Identifiers -> Module -> (Text, Text, Text, Text)
getModuleNameParts idents (Module spec prog oracle calledF _ mbPreCheckedFuncAndCallStack) =
  case beginOfModule prog of
    Nothing -> ("", "empty: " <> pprExpr post, "", "")
    Just label ->
      let scopedNames = labelNamesOfPc idents label
          isFloatingLabel = label /= calledF
          (prefix, labelsSummary) = normalizedName scopedNames isFloatingLabel
       in (prefix, labelsSummary, descrOfOracle oracle, preCheckingSuffix)
 where
  post = fs_post spec
  preCheckingSuffix = case mbPreCheckedFuncAndCallStack of
    Nothing -> ""
    Just (callstack, f) ->
      let fName = toText . dropMain . sf_scopedName $ f
          stackDigest = digestOfCallStack (Map.map sf_scopedName (pcToFun idents)) callstack
       in " Pre<" <> fName <> "|" <> stackDigest <> ">"

data Error
  = ELoopNoInvariant Label
  | EInvariantWithSVarUpdateSpec

instance Show Error where
  show (ELoopNoInvariant at) = printf "There is a loop at PC %d with no invariant" (unLabel at)
  show EInvariantWithSVarUpdateSpec =
    "Some function contains an assertion or invariant, but has a spec with @storage_update annotations."

data ModuleF a
  = EmitModule Module a
  | forall b. Visiting (NonEmpty Label, Map (NonEmpty Label, Label) Bool, Vertex) (Bool -> ModuleL b) (b -> a)
  | Throw Error
  | forall b. Catch (ModuleL b) (Error -> ModuleL b) (b -> a)

deriving stock instance Functor ModuleF

newtype ModuleL a = ModuleL {runModuleL :: F ModuleF a}
  deriving newtype (Functor, Applicative, Monad)

instance MonadError Error ModuleL where
  throwError = throw
  catchError = catch

liftF' :: ModuleF a -> ModuleL a
liftF' = ModuleL . liftF

-- | Emit the module 'm', which needs to be verified.
emitModule :: Module -> ModuleL ()
emitModule m = liftF' (EmitModule m ())

{- | Perform the action on the path where the label 'l' has been marked
   as visited.

'm' additionally takes a parameter that tells whether 'l' has been
visited before.
-}
visiting :: (NonEmpty Label, Map (NonEmpty Label, Label) Bool, Vertex) -> (Bool -> ModuleL b) -> ModuleL b
visiting vertexDesc action = liftF' (Visiting vertexDesc action id)

throw :: Error -> ModuleL a
throw t = liftF' (Throw t)

catch :: ModuleL a -> (Error -> ModuleL a) -> ModuleL a
catch m h = liftF' (Catch m h id)

data SpecBuilder = SBRich | SBPlain (Expr TBool)

extractPlainBuilder :: FuncSpec -> ModuleL SpecBuilder
extractPlainBuilder (FuncSpec pre _ storage)
  | not (null storage) = throwError EInvariantWithSVarUpdateSpec
  | otherwise = pure (SBPlain (pre .&& (ap .== fp)))

gatherModules :: CFG -> [(Function, ScopedName, FuncSpec)] -> ModuleL ()
gatherModules cfg = traverse_ $ \(f, _, spec) -> gatherFromSource cfg f spec

{- | This function represents a depth first search through the CFG that uses as sentinels
(for where to begin and where to end) assertions in nodes, such that nodes that are not annotated
are traversed without stopping the search, gathering labels from respective edges that
represent instructions and concatenating them into final Modules, that are subsequently
transformed into actual *.smt2 queries.

Thus, a module can comprise of 0 to several segments, where the precondition of the module
is the annotation of the node 'begin' that begins the first segment, the postcondition of the module
is the annotation of the node 'end' that ends the last segment and instructions of the module
are a concatenation of edge labels for the given path through the graph from 'begin' to 'end'.

Note that NO node with an annotation can be encountered in the middle of one such path,
because annotated nodes are sentinels and the search would terminate.

We distinguish between plain and rich modules.
A plain module is a self-contained 'sub-program' with its own semantics that is referentially pure
in the sense that it has no side-effects on the environment, i.e. does not access storage variables.

A rich module is very much like a plain module except it allows side effects,
i.e. accesses to storage variables.
-}
gatherFromSource :: CFG -> Function -> FuncSpec -> ModuleL ()
gatherFromSource cfg function fSpec = do
  let verticesAtFuPc = verticesLabelledBy cfg $ fu_pc function
  for_ verticesAtFuPc $ \v ->
    visit Map.empty (initialWithFunc (fu_pc function)) [] SBRich v ACNone Nothing
 where
  {- Revisiting nodes (thus looping) within the CFG is verboten in all cases but one,
     specifically when we are jumping back to a label that is annotated with an invariant 'inv'.
     In this case, we pretend that the 'begin' and 'end' is the same node, both of which
     annotated with 'inv'.

     Thus, visit needs a way to keep track of nodes that have already been visited. However,
     it is important to note that it is not sufficient to keep track of which program counters
     we have touched in the CFG, as there are several ways to 'validly' revisit the same PC
     without loopy behaviour, most prominently stemming from existence of ifs that converge
     on the same path and presence of inlining where the same function can be called multiple times.

     In order to distinguish valid nodes in this context, we need the oracle for ifs as described in
     the docs of getModuleNameParts and we need the callstack which keeps track of inlined functions
     in very much the same way as 'normal' callstacks work, thus allowing us to identify
     whether the execution of the current function is unique, or being revisited through
     a 'wrong' path through the CFG.

     Oracles need a bit of extra information about which booltest passed - in the form of ArcCondition
     and CallStack needs a bit of extra information about when call/ret are called, in the form of FInfo. -}
  visit ::
    Map (NonEmpty Label, Label) Bool ->
    CallStack ->
    [LabeledInst] ->
    SpecBuilder ->
    Vertex ->
    ArcCondition ->
    FInfo ->
    ModuleL ()
  visit oracle callstack acc builder v arcCond f =
    visiting (stackTrace callstack', oracle, v) $ \alreadyVisited ->
      if alreadyVisited then visitLoop builder else visitLinear builder
   where
    l = v_label v

    visitLoop SBRich = extractPlainBuilder fSpec >>= visitLoop
    visitLoop (SBPlain pre)
      | null assertions = throwError (ELoopNoInvariant l)
      | otherwise = emitPlain pre (Expr.and assertions)

    visitLinear SBRich
      | onFinalNode = emitRich (fs_pre fSpec) (Expr.and $ map snd (cfg_assertions cfg ^. ix v))
      | null assertions = visitArcs oracle' acc builder v
      | otherwise = extractPlainBuilder fSpec >>= visitLinear
    visitLinear (SBPlain pre)
      | null assertions = visitArcs oracle' acc builder v
      | otherwise = do
          emitPlain pre (Expr.and assertions)
          visitArcs Map.empty [] (SBPlain (Expr.and assertions)) v

    callstack' = case f of
      Nothing -> callstack
      Just (ArcCall fCallerPc fCalledF) -> push (fCallerPc, fCalledF) callstack
      Just ArcRet -> snd $ pop callstack
    oracle' = updateOracle arcCond callstack' oracle
    assertions = map snd (cfg_assertions cfg ^. ix v)
    onFinalNode = null (cfg_arcs cfg ^. ix v)

    preCheckingStackFrame = (fCallerPc, fCalledF)
     where
      labelledCall@(fCallerPc, _) = last acc
      fCalledF = uncheckedCallDestination labelledCall
    preCheckingContext =
      (push preCheckingStackFrame callstack',) <$> v_preCheckedF v

    emitPlain pre post = emit preCheckingContext $ FuncSpec pre post Map.empty
    emitRich pre post = emit preCheckingContext $ FuncSpec pre post $ fs_storage fSpec

    emit mbTrace spec = emitModule $ Module spec acc oracle' (fu_pc function) (callstack', l) mbTrace

    visitArcs newOracle acc' pre v' = do
      let outArcs = cfg_arcs cfg ^. ix v'
      unless (null outArcs) $
        let isCalledBy = (moveLabel (callerPcOfCallEntry $ top callstack') sizeOfCall ==) . v_label
            outArcs' = filter (\(dst, _, _, f') -> not (isRetArc f') || isCalledBy dst) outArcs
         in for_ outArcs' $ \(lTo, insts, test, f') ->
              visit newOracle callstack' (acc' <> insts) pre lTo test f'

updateOracle ::
  ArcCondition ->
  CallStack ->
  Map (NonEmpty Label, Label) Bool ->
  Map (NonEmpty Label, Label) Bool
updateOracle ACNone _ = id
updateOracle (ACJnz jnzPc isSat) callstack =
  Map.insert (stackTrace callstack, jnzPc) isSat

module IdePurescript.Build where

import Prelude
import Node.ChildProcess as CP
import Node.Stream as S
import PscIde as P
import PscIde.Command as PC
import Control.Monad.Aff (Aff, makeAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (log, CONSOLE)
import Control.Monad.Eff.Exception (EXCEPTION, error, catchException)
import Control.Monad.Eff.Ref (readRef, REF, modifyRef, newRef)
import Control.Monad.Eff.Unsafe (unsafeInterleaveEff)
import Control.Monad.Error.Class (throwError)
import Data.Array (uncons, singleton)
import Data.Bifunctor (bimap)
import Data.Either (either, Either(..))
import Data.Foldable (find)
import Data.Maybe (maybe, Maybe(..))
import Data.StrMap (fromList)
import Data.String (split, indexOf)
import Data.Traversable (traverse_)
import Data.Tuple (Tuple(Tuple))
import Data.List as List
import IdePurescript.Exec (findBins, getPathVar)
import IdePurescript.PscErrors (PscError(PscError), RebuildResult(RebuildError, RebuildResult), PscResult, parsePscOutput)
import Node.Buffer (BUFFER)
import Node.ChildProcess (ChildProcess, CHILD_PROCESS)
import Node.Encoding (Encoding(UTF8))
import Node.FS (FS)
import Node.Process (PROCESS)
import PscIde (NET)
import PscIde.Server (Executable(Executable))

type BuildOptions =
  { command :: Command
  , directory :: String
  , useNpmDir :: Boolean
  }

data Command = Command String (Array String)

newtype BuildError = BuildError {}
type BuildResult =
  { errors :: PscResult
  , success :: Boolean
  }

addExceptionEffect :: forall eff a. Eff eff a -> Eff (err :: EXCEPTION | eff) a
addExceptionEffect = unsafeInterleaveEff

spawn :: forall eff. BuildOptions
  -> Aff (cp :: CHILD_PROCESS, buffer :: BUFFER, fs :: FS, process :: PROCESS | eff)
      { cmdBins :: Array Executable, cp :: Maybe ChildProcess }
spawn { command: Command cmd args, directory, useNpmDir } = do
  pathVar <- liftEff $ getPathVar useNpmDir directory
  cmdBins <- findBins pathVar cmd
  cp <- liftEff $ case uncons cmdBins of
    Just { head: Executable cmdBin _ } -> Just <$>
      CP.spawn cmdBin args (CP.defaultSpawnOptions { cwd = Just directory, env = Just (fromList $ List.singleton $ Tuple "PATH" $ either id id pathVar) })
    _ -> pure Nothing
  pure { cmdBins, cp }

type BuildEff eff = (cp :: CP.CHILD_PROCESS, buffer :: BUFFER, fs :: FS, console :: CONSOLE, ref :: REF, process :: PROCESS | eff)
build :: forall eff. BuildOptions -> Aff (BuildEff eff) BuildResult
build buildOptions@{ command: Command cmd args, directory, useNpmDir } = do
  { cmdBins, cp: cp' } <- spawn buildOptions
  makeAff $ \err succ -> do
    log $ "Resolved build command (1st is used): "
    traverse_ (\(Executable x vv) -> do
      log $ x <> maybe "" (": " <> _) vv) cmdBins
    case cp' of
      Nothing -> err $ error $ "Didn't find command in PATH: " <> cmd
      Just cp -> do
        CP.onError cp (err <<< CP.toStandardError)
        let stderr = CP.stderr cp
        result <- newRef ""
        let res :: String -> Eff (BuildEff (err :: EXCEPTION | eff)) Unit
            res s = do
              modifyRef result (\acc -> acc<>s)

        catchException err $ S.onDataString stderr UTF8 res
        CP.onClose cp (\exit -> case exit of
          CP.Normally n | n == 0 || n == 1 -> do
            pscOutput <- readRef result
            let lines = split "\n" pscOutput
                json = find (\s -> indexOf "{\"" s == Just 0) lines
            case parsePscOutput <$> json of
              Just (Left e) -> err $ error e
              Just (Right r) -> succ { errors: r, success: n == 0 }
              Nothing -> err $ error "Didn't find JSON output"
          _ -> err $ error "Process exited abnormally")

rebuild :: forall eff. Int -> String -> Aff (net :: NET | eff) BuildResult
rebuild port file = do

  res <- rebuild' port file
  either
    (throwError <<< error)
    (pure <<< onResult)
    res
  where
  wrapError :: RebuildResult -> Array PscError
  wrapError (RebuildError s) = singleton $ PscError
    { moduleName: Nothing
    , errorCode: "RebuildStringError"
    , message: s
    , filename: Just file
    , position: Nothing
    , errorLink: ""
    , suggestion: Nothing
    }
  wrapError (RebuildResult errs) = errs

  onResult :: Either RebuildResult RebuildResult -> BuildResult
  onResult =
    either (\errors -> { errors: { errors, warnings: [] }, success: true })
           (\warnings -> { errors: { errors: [], warnings }, success: true  })
    <<<
    bimap wrapError wrapError

  rebuild' :: Int -> String -> P.CmdR RebuildResult RebuildResult
  rebuild' port file = P.sendCommandR port (PC.RebuildCmd file)

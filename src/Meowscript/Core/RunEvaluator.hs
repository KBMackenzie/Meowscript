{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Meowscript.Core.RunEvaluator
( runMeow
, runExpr
, runMeow'
, runExpr'
, runMeowDebug
, EvalCallback
, ExprCallback
) where

import Meowscript.Core.AST
import Meowscript.Core.Base
import Meowscript.Core.Environment
import Meowscript.Core.Blocks
import Meowscript.Parser.RunParser
import Meowscript.Core.Exceptions
import Meowscript.Core.Pretty
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Data.Map as Map
import qualified Data.List as List
import Control.Monad.Reader (ask, runReaderT, liftIO)
import Control.Monad.Except (runExceptT, throwError)
import Data.IORef

type EvalCallback a = [Statement] -> Evaluator a
type ExprCallback a = Expr -> Evaluator a

runEvaluator :: IO ObjectMap -> Evaluator a -> IO (Either Text.Text a)
runEvaluator env eval = env >>= newIORef >>= (runExceptT . runReaderT eval)

-- Evaluate contents from file.
runMeow :: IO ObjectMap -> EvalCallback a -> FilePath -> IO (Either Text.Text a)
runMeow lib fn path = meowParse path >>= \case
    (Left exception) -> (return . Left) exception
    (Right program) -> do
        env <- (<>) <$> lib <*> baseLibrary
        (runEvaluator (return env) . fn) program

-- Evaluate contents from string.
runExpr :: IO ObjectMap -> ExprCallback a -> Text.Text -> IO (Either Text.Text a)
runExpr lib fn str = exprString str >>= \case
    (Left exception) -> (return . Left) exception
    (Right expr) -> do 
        env <- (<>) <$> lib <*> baseLibrary
        (runEvaluator (return env) . fn) expr

-- Variants that default to no additional libraries:
runMeow' :: FilePath -> IO (Either Text.Text Prim)
runMeow' = runMeow (return Map.empty) runProgram

runExpr' :: Text.Text -> IO (Either Text.Text Prim)
runExpr' = runExpr (return Map.empty) evaluate

runMeowDebug :: FilePath -> IO (Either Text.Text Prim)
runMeowDebug = runMeow (return Map.empty) runDebug


{- Run program with imports. -}
runProgram :: [Statement] -> Evaluator Prim
runProgram xs = do
    let (imps, rest) = List.partition isImport xs
    mapM_ addImport imps
    returnAsPrim <$> runBlock rest False

runAsImport :: [Statement] -> Evaluator Environment
runAsImport xs = runProgram xs >> ask -- Return the environment.

runDebug :: [Statement] -> Evaluator Prim
runDebug xs = do
    ret <- runProgram xs
    x <- (ask >>= liftIO . readIORef) >>= showMeow . MeowObject
    (liftIO . TextIO.putStrLn) x
    return ret

getImportEnv :: FilePath -> IO (Either Text.Text Environment)
getImportEnv path = runMeow (return Map.empty) runAsImport path >>= \case
    (Left exception) -> (return . Left) exception
    (Right output) -> (return . Right) output

addImport :: Statement -> Evaluator ()
addImport (StmImport file qualified) = (liftIO . getImportEnv) file >>= \case
    (Left ex) -> throwError (badImport file ex)
    (Right import') -> case qualified of
        Nothing -> do
            x <- ask >>= liftIO . readIORef
            y <- (liftIO . readIORef) import'
            ask >>= liftIO . flip writeIORef (x <> y)
        (Just x) -> do
            imp <- (liftIO . readIORef) import' >>= liftIO . newIORef . MeowObject
            insertRef x imp
addImport x = throwError (showException MeowBadImport "Critical error: Statement is not an import! Trace: " `Text.append` showT x)

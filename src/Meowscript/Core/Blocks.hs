{-# LANGUAGE OverloadedStrings #-} 
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

module Meowscript.Core.Blocks
( evaluate
, runBlock
, isFuncDef
, isImport
) where

import Meowscript.Core.AST
import Meowscript.Core.Operations
import Meowscript.Core.Environment
import Meowscript.Core.Keys
import Meowscript.Core.Pretty
import Meowscript.Core.Exceptions
import Meowscript.Parser.Keywords
import qualified Data.Text as Text
import qualified Data.List as List
import Control.Monad.Reader (asks, liftIO)
import Control.Monad.Except (throwError)
import Control.Monad (void, join, when, (>=>))
import Data.Functor ((<&>))

type Args = [Prim]

{- Evaluating Expressions -}
evaluate :: Expr -> Evaluator Prim
evaluate (ExpPrim prim) = return prim
evaluate (ExpBinop op a b) = join (binop op <$> evaluate a <*> evaluate b)
evaluate (ExpUnop op a) = evaluate a >>= unop op
evaluate (ExpList list) = mapM (evaluate >=> ensureValue) list <&> MeowList
evaluate (ExpObject object) = do
    let toPrim (key, expr) = (evaluate expr >>= ensureValue) <&> (key,)
    pairs <- mapM toPrim object
    MeowObject <$> (liftIO . createObject) pairs
evaluate (ExpLambda args expr) = asks (MeowFunc args [StmReturn expr])
evaluate x@(ExpTrail {}) = MeowKey . KeyRef <$> trailReduce x

-- Function call
evaluate (ExpCall args funcKey) = do
    args' <- mapM (evaluate >=> ensureValue) args
    evaluate funcKey >>= \case
        (MeowKey key) -> funcLookup key args'
        lambda@(MeowFunc {}) -> runFunc "<lambda>" args' lambda
        x -> throwError =<< notFunc x

-- Yarn operator
evaluate (ExpYarn expr) = (evaluate >=> ensureValue) expr >>= \case
    (MeowString str) -> (return . MeowKey . KeyNew) str
    x -> throwError =<< opException "Yarn" [x]

-- Boolean operators (&&, ||)
evaluate (ExpMeowAnd exprA exprB) = boolEval exprA >>= \case
    False -> (return . MeowBool) False
    True -> MeowBool <$> boolEval exprB
evaluate (ExpMeowOr exprA exprB) = boolEval exprA >>= \case
    True -> (return . MeowBool) True
    False -> MeowBool <$> boolEval exprB

-- Ternary operator
evaluate (ExpTernary cond exprA exprB) = boolEval cond >>= \case
    True -> evaluate exprA
    False -> evaluate exprB
    
------------------------------------------------------------------------

{- Trails -}

trailToRef :: Expr -> Evaluator PrimRef
trailToRef = trailReduce >=> pairAsRef

trailReduce :: Expr -> Evaluator (PrimRef, Prim)
trailReduce (ExpTrail x y) = evaluate x >>= \case
    (MeowKey key) -> (extractKey >=> lookUpRef) key >>= innerTrail y
    obj@(MeowObject _) -> newMeowRef obj >>= innerTrail y
    other -> throwError =<< badTrail [other]
trailReduce x = throwError =<< (evaluate >=> ensureValue >=> badTrail . List.singleton) x

innerTrail :: Expr -> PrimRef -> Evaluator (PrimRef, Prim)
innerTrail (ExpTrail x y) ref = innerTrail y =<<
    ((,) <$> (evaluate >=> ensureKey) x <*> readMeowRef ref >>= uncurry peekAsObject)
innerTrail prim ref = (ref,) <$> evaluate prim


{-- Helpers --}

-- Helper functions to distinguish between statements.
isFuncDef :: Statement -> Bool
{-# INLINABLE isFuncDef #-}
isFuncDef (StmFuncDef {}) = True
isFuncDef _ = False

isImport :: Statement -> Bool
{-# INLINABLE isImport #-}
isImport (StmImport {}) = True
isImport _ = False

boolEval :: Expr -> Evaluator Bool
{-# INLINABLE boolEval #-}
boolEval x = (evaluate >=> ensureValue) x <&> meowBool

------------------------------------------------------------------------

funcTrace :: Key -> Args -> Evaluator a -> Evaluator a
funcTrace key args = stackTrace $ do
    args' <- mapM prettyMeow args <&> Text.intercalate ", "
    return $ Text.concat [ "In function '", key, "'. Arguments: [", args', "]" ]

------------------------------------------------------------------------

{-- Blocks --}

-- Run block in proper order: Function definitions, then other statements.
runBlock :: Block -> IsLoop -> Evaluator ReturnValue
{-# INLINABLE runBlock #-}
runBlock xs isLoop = do
    let (funcDefs, rest) = List.partition isFuncDef xs
    void $ runStatements funcDefs False
    runStatements rest isLoop

-- Running Statements
runStatements :: Block -> IsLoop -> Evaluator ReturnValue
runStatements [] _ = return RetVoid
runStatements ((StmReturn value):_) _ = RetValue <$> (evaluate value >>= ensureValue)
runStatements (StmBreak:_) isLoop = if isLoop
                                        then return RetBreak
                                        else throwError (notInLoop meowBreak)
runStatements (StmContinue:_) isLoop = if isLoop
                                        then return RetContinue
                                        else throwError (notInLoop meowContinue)
runStatements ((StmExpr expression):xs) isLoop =
    runExprStatement expression >> runStatements xs isLoop
runStatements ((StmFuncDef name args body):xs) isLoop =
    runFuncDef (KeyNew name) args body >> runStatements xs isLoop
runStatements (statement:xs) isLoop = do
    ret <- runLocal $ runTable statement isLoop
    if ret /= RetVoid
        then return ret
        else runStatements xs isLoop

-- Action table for all other statement blocks.
runTable :: Statement -> IsLoop -> Evaluator ReturnValue
{-# INLINABLE runTable #-}
runTable (StmWhile a b) _ = runWhile a b
runTable (StmFor a b) _ = runFor a b
runTable (StmIfElse as b) isLoop = runIfElse as b isLoop
runTable (StmIf as) isLoop = runIf as isLoop
runTable (StmImport a _) _ = throwError (nestedImport a)
runTable x _ = throwError ("Critical failure: Invalid statement. Trace: " `Text.append` showT x)

runExprStatement :: Expr -> Evaluator Prim
{-# INLINABLE runExprStatement #-}
runExprStatement = evaluate 

------------------------------------------------------------------------

{-- Functions --}
runFuncDef :: KeyType -> Params -> Block -> Evaluator ReturnValue
runFuncDef key params body = do 
    asks (MeowFunc params body) >>= assignment key
    return RetVoid

{- Run Functions -}
funcLookup :: KeyType -> Args -> Evaluator Prim
funcLookup key args = case key of 
    (KeyModify x) -> runMeow x
    (KeyNew x) -> runMeow x
    (KeyRef (ref, x)) -> do
        funcKey <- ensureKey x
        fn <- readMeowRef ref >>= peekAsObject funcKey >>= readMeowRef
        runMethod funcKey args ref fn
    where runMeow x = lookUp x >>= runFunc x args

meowFunc :: Key -> Params -> Args -> [Statement] -> Evaluator Prim
meowFunc key params args body = do
    paramGuard key args params
    addFunArgs (zip params args)
    returnAsPrim <$> runBlock body False

iFunc :: Key -> Params -> Args -> InnerFunc -> Evaluator Prim
iFunc key params args fn = do
    paramGuard key args params
    addFunArgs (zip params args)
    fn
    
runFunc :: Key -> Args -> Prim -> Evaluator Prim
runFunc key args (MeowIFunc params fn) = runLocal $ iFunc key params args fn
runFunc key args (MeowFunc params body closure) = funcTrace key args $ do 
    closure' <- readMeowRef closure
    runClosure closure' $ meowFunc key params args body
runFunc key _ _ = throwError (badFunc key)

runMethod :: Key -> Args -> PrimRef -> Prim -> Evaluator Prim
runMethod key args _ (MeowIFunc params fn) =
    runLocal $ iFunc key params args fn
runMethod key args parent (MeowFunc params body closure) = funcTrace key args $ do 
    closure' <- readMeowRef closure
    runClosure closure' $ do
        insertRef "home" parent
        meowFunc key params args body
runMethod key _ _ _ = throwError (badFunc key)

addFunArgs :: [(Key, Prim)] -> Evaluator ()
{-# INLINABLE addFunArgs #-}
addFunArgs [] = return ()
addFunArgs ((key, prim):xs) = do
    assignNew key prim
    addFunArgs xs

paramGuard :: Key -> Args -> Params -> Evaluator ()
{-# INLINABLE paramGuard #-}
paramGuard key args params = do
    when (length params < length args) (throwError =<< manyArgs key args)
    when (length params > length args) (throwError =<< fewArgs  key args)

------------------------------------------------------------------------

{- If Else -}
runIf :: [MeowIf] -> IsLoop -> Evaluator ReturnValue
runIf [] _ = return RetVoid
runIf ((MeowIf cond body):xs) isLoop = do
    condition <- boolEval cond
    if condition
      then runBlock body isLoop
      else runIf xs isLoop

runIfElse :: [MeowIf] -> Block -> IsLoop -> Evaluator ReturnValue
runIfElse [] elseBlock isLoop = runBlock elseBlock isLoop
runIfElse ((MeowIf cond body):xs) elseBlock isLoop = do
    condition <- boolEval cond
    if condition
        then runBlock body isLoop
        else runIfElse xs elseBlock isLoop

{- While Loop -}
-- Notes: Any return value that isn't RetVoid implies the end of the loop.
runWhile :: Condition -> Block -> Evaluator ReturnValue
runWhile x body = do
    condition <- boolEval x
    if condition
        then innerWhile x body
        else return RetVoid

innerWhile :: Condition -> Block -> Evaluator ReturnValue
innerWhile x body = runLocal $ do
    ret <- runBlock body True
    condition <- boolEval x
    if condition && not (shouldBreak ret)
        then innerWhile x body
        else return $ case ret of
            RetContinue -> RetVoid
            RetBreak -> RetVoid
            ret' -> ret'

{- For Loop -}
-- Notes: Any return value that isn't RetVoid implies the end of the loop.
runFor :: (Expr, Expr, Expr) -> Block -> Evaluator ReturnValue
runFor xs@(init', _, cond) body = do
    (void . evaluate) init'
    condition <- boolEval cond
    if condition
        then innerFor xs body
        else return RetVoid

innerFor :: (Expr, Expr, Expr) -> Block -> Evaluator ReturnValue
innerFor xs@(_, incr, cond) body = runLocal $ do
    ret <- runBlock body True
    (void . evaluate) incr
    condition <- boolEval cond
    if condition && not (shouldBreak ret)
        then innerFor xs body
        else return $ case ret of
            RetContinue -> RetVoid
            RetBreak -> RetVoid
            ret' -> ret'

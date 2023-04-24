{-# LANGUAGE OverloadedStrings #-} 

module Meowscript.Parser.Expr
( parseExpr
, parseExpr'
) where

import Meowscript.Core.AST
import Meowscript.Parser.Core
import Text.Megaparsec ((<|>))
import qualified Text.Megaparsec as Mega
import qualified Text.Megaparsec.Char as MChar
import Control.Monad.Combinators.Expr (Operator(..), makeExprParser)

exprTerm :: Parser Expr
exprTerm = (lexeme . parens) parseExpr
    <|> (EPrim <$> lexeme parsePrim)

parseExpr :: Parser Expr
parseExpr = makeExprParser exprTerm operators

parseExpr' :: Parser Expr
parseExpr' = lexeme (whitespace >> parseExpr)

operators :: [[Operator Parser Expr]]
operators =
    [
        [ Prefix  (EUnop MeowYarn    <$ trySymbol "~~"   ) ]
      , [ Prefix  (EUnop MeowNegate  <$ symbol "-"      )
        , Prefix  (EUnop MeowNot     <$ trySymbol "paw" ) ]
      , [ Postfix (EUnop MeowYarnLen <$ symbol "~?"   ) ]
      , [ InfixL (EBinop MeowMul <$ symbol "*")
        , InfixL (EBinop MeowDiv <$ symbol "/") ]
      , [ InfixL (EBinop MeowAdd <$ symbol "+")
        , InfixL (EBinop MeowSub <$ symbol "-") ]
      , [ InfixL (EBinop MeowPoke   <$ trySymbol "poke!" )
        , InfixL (EBinop MeowConcat <$ trySymbol ".."    ) ]
      , [ InfixL (EBinop (MeowCompare [LT, EQ]) <$ trySymbol "<=")
        , InfixL (EBinop (MeowCompare [GT, EQ]) <$ trySymbol ">=")
        , InfixL (EBinop (MeowCompare [LT])     <$ symbol "<" )
        , InfixL (EBinop (MeowCompare [GT])     <$ symbol ">" ) ]
      , [ InfixL (EBinop (MeowCompare [EQ])     <$ trySymbol "==")
        , InfixL (EBinop (MeowCompare [LT, GT]) <$ trySymbol "!=") ]
      , [ InfixL (EBinop MeowAnd    <$ trySymbol "nya"      ) ]
      , [ InfixL (EBinop MeowOr     <$ trySymbol "push"     ) ]
      , [ InfixL (EBinop MeowAssign <$ trySymbol "=^.x.^="  ) ]
    ]

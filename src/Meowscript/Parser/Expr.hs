{-# LANGUAGE OverloadedStrings #-} 

module Meowscript.Parser.Expr
( parseExpr
, parseExpr'
) where

import Meowscript.Core.AST
import Meowscript.Parser.Core
import Meowscript.Parser.Keywords
import Text.Megaparsec ((<|>), (<?>))
import qualified Text.Megaparsec as Mega
import qualified Text.Megaparsec.Char as MChar
import Control.Monad.Combinators.Expr (Operator(..), makeExprParser)
import Control.Monad (void)
import Data.Char (isNumber)

exprTerm :: Parser Expr
exprTerm = ((lexeme . parens) parseExpr <?> "parens"    )
    <|> (lexeme parseBox                <?> "box"       )
    <|> (lexeme parseList               <?> "list"      )
    <|> (EPrim <$> lexeme parsePrim                     ) 

parseExpr :: Parser Expr
parseExpr = makeExprParser exprTerm operators

parseExpr' :: Parser Expr
parseExpr' = lexeme (whitespace >> parseExpr)

operators :: [[Operator Parser Expr]]
operators =
    [
        [ Prefix  (EUnop MeowYarn                   <$ trySymbol "~~"        ) ]
      , [ InfixL  (ETrail                             <$ parseDotOp            ) ]
      , [ Postfix (Mega.try functionCall                                     ) ]
      , [ Prefix  (EUnop  MeowPeek                  <$ tryKeyword meowPeek   )
        , InfixL  (EBinop MeowPush                  <$ tryKeyword meowPush   )
        , Prefix  (EUnop  MeowKnockOver             <$ tryKeyword meowKnock  )
        , Postfix (EUnop  MeowLen                   <$ symbol "?"            )
        , InfixL  (EBinop MeowConcat                <$ trySymbol ".."        ) ]
      , [ Prefix  (EUnop  MeowPaw                   <$ tryKeyword meowPaw    )
        , Prefix  (EUnop  MeowClaw                  <$ tryKeyword meowClaw   )
        , Prefix  (EUnop  MeowNegate                <$ symbol "-"            )
        , Prefix  (EUnop  MeowNot                   <$ tryKeyword meowNot    ) ]
      , [ InfixL  (EBinop MeowMul                   <$ symbol "*"            )
        , InfixL  (EBinop MeowDiv                   <$ symbol "/"            )
        , InfixL  (EBinop MeowMod                   <$ symbol "%"            ) ]
      , [ InfixL  (EBinop MeowAdd                   <$ symbol "+"            )
        , InfixL  (EBinop MeowSub                   <$ symbol "-"            ) ]
      , [ InfixL  (EBinop (MeowCompare [LT, EQ])    <$ trySymbol "<="        )
        , InfixL  (EBinop (MeowCompare [GT, EQ])    <$ trySymbol ">="        )
        , InfixL  (EBinop (MeowCompare [LT])        <$ symbol "<"            )
        , InfixL  (EBinop (MeowCompare [GT])        <$ symbol ">"            ) ]
      , [ InfixL  (EBinop (MeowCompare [EQ])        <$ trySymbol "=="        )
        , InfixL  (EBinop (MeowCompare [LT, GT])    <$ trySymbol "!="        ) ]
      , [ InfixL  (EBinop MeowAnd                   <$ tryKeyword "and"      ) ]
      , [ InfixL  (EBinop MeowOr                    <$ tryKeyword "or"       ) ]
      , [ Prefix  parseLambda                                                  ]
      , [ InfixR  (EBinop MeowAssign                <$ symbol "="            ) ]
    ]

functionCall :: Parser (Expr -> Expr)
functionCall = (lexeme . parens) $
    whitespace >>
    ECall <$> sepByComma (lnLexeme parseExpr)

parseList :: Parser Expr
parseList = (lexeme . brackets) $
    whitespaceLn >>
    EList <$> sepByComma (lnLexeme parseExpr)

parseBox :: Parser Expr
parseBox = (Mega.try . lexemeLn . MChar.string) meowBox >> parseBox'

parseBox' :: Parser Expr
parseBox' = (lexeme . brackets) $
    whitespaceLn >>
    EObject <$> sepByComma (lnLexeme parseKeyValue) <* whitespaceLn

parseKeyValue :: Parser (Key, Expr)
parseKeyValue = do
    key <- lexeme keyText
    (void . lexeme) (MChar.char ':')
    expression <- lexeme parseExpr
    return (key, expression)

parseLambda :: Parser (Expr -> Expr)
parseLambda = do
    (void . Mega.try . lexeme . MChar.string) meowLambda
    let takeArgs = (sepByComma . flexeme) keyText
    args <- (lexeme . parens) (whitespace >> takeArgs)
    (void . lexeme . MChar.string) "=>"
    return (ELambda args)

parseDotOp :: Parser ()
parseDotOp = Mega.try $ do
    void $ MChar.char '.'
    Mega.notFollowedBy $ Mega.satisfy (== '.')

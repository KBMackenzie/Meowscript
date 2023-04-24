{-# LANGUAGE OverloadedStrings #-} 

module Meowscript.Parser.Statements
( root
, statements
) where

import Meowscript.Core.AST
import Meowscript.Parser.Core
import Meowscript.Parser.Expr
import qualified Data.Text as Text
import Text.Megaparsec ((<|>), (<?>))
import qualified Text.Megaparsec as Mega
import qualified Text.Megaparsec.Char as MChar
import qualified Text.Megaparsec.Char.Lexer as Lexer
import Control.Monad (void)
import Text.Megaparsec.Char.Lexer (nonIndented)

root :: Parser Statement
root = SAll <$> Mega.between whitespace Mega.eof (Mega.many statements)

statements :: Parser Statement
statements = Mega.choice
    [ Mega.try parseIf
    , Mega.try parseWhile
    , Mega.try parseIfElse
    , Mega.try parseFunc
    , Mega.try parseReturn
    , exprS
    , fail "Invalid token!" ]

asLeave :: ([Statement] -> Statement) -> [Statement] -> Parser Statement
asLeave f xs = do
    whitespace
    void $ keyword "leave"
    return (f xs)

condition :: Parser Expr
condition = (lexeme . bars) parseExpr'

exprS :: Parser Statement
exprS = SExpr <$> parseExpr'


{- If -}

asIf :: Expr -> [Statement] -> Parser Statement
asIf e = asLeave (SOnlyIf e)

parseIf :: Parser Statement
parseIf = lexeme $ Lexer.indentBlock whitespaceLn $ do
    void $ keyword "mew?"
    whitespace
    c <- condition
    return (Lexer.IndentMany Nothing (asIf c) statements)


{- While -}

asWhile :: Expr -> [Statement] -> Parser Statement
asWhile e = asLeave (SWhile e)

parseWhile:: Parser Statement
parseWhile = lexeme $ Lexer.indentBlock whitespaceLn $ do
    void $ keyword "scratch"
    whitespace
    c <- condition
    return (Lexer.IndentMany Nothing (asWhile c) statements)



{- If Else -}

bAsIf :: Expr -> [Statement] -> Parser ([Statement] -> Statement)
bAsIf e xs = return $ SIfElse e xs

bAsElse :: ([Statement] -> Statement) -> [Statement] -> Parser Statement
bAsElse f xs = do
    void $ keyword "leave"
    return (f xs)

parseIfElse :: Parser Statement
parseIfElse = do
    x <- parseBIf
    parseBElse x

parseBIf :: Parser ([Statement] -> Statement)
parseBIf = lexeme $ Lexer.indentBlock whitespaceLn $ do
    void $ keyword "mew?"
    whitespace
    c <- condition
    return (Lexer.IndentMany Nothing (bAsIf c) statements)

parseBElse :: ([Statement] -> Statement) -> Parser Statement
parseBElse f = lexeme $ Lexer.indentBlock whitespaceLn $ do
    void $ keyword "hiss!"
    return (Lexer.IndentMany Nothing (bAsElse f) statements)


{- Functions -}

funName :: Parser Text.Text
funName = atomName <$> lexeme (whitespace >> parseAtom)

funArgs :: Parser [Text.Text]
funArgs = (lexeme . bars) $ do
    whitespace
    args <- Mega.sepBy (whitespace >> parseAtom) (MChar.char ',')
    whitespace
    return $ atomName <$> args

asFunc :: Text.Text -> [Text.Text] -> [Statement] -> Parser Statement
asFunc name args = asLeave (SFuncDef name args)

parseFunc :: Parser Statement
parseFunc = lexeme $ Lexer.indentBlock whitespaceLn $ do
    void $ keyword "purr"
    name <- funName
    args <- funArgs
    return (Lexer.IndentMany Nothing (asFunc name args) statements)


{- Return -}

parseReturn :: Parser Statement
parseReturn = do
    whitespace
    void $ keyword "bring gift"
    SReturn <$> parseExpr'

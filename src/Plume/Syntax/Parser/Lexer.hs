{-# LANGUAGE MultiWayIf #-}

module Plume.Syntax.Parser.Lexer where

import Control.Monad.Parser
import Data.Text (pack)
import System.IO.Unsafe
import Text.Megaparsec hiding (many, some)
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer qualified as L
import Prelude hiding (modify)

indentation :: IORef Int
indentation = unsafePerformIO $ newIORef 0

lineComment :: Parser ()
lineComment = L.skipLineComment "//"

multilineComment :: Parser ()
multilineComment = L.skipBlockComment "/*" "*/"

indentSc :: Parser ()
indentSc =
  skipMany
    ( choice
        [ try $ space *> lineComment
        , try $ space *> multilineComment
        , void eol
        ]
    )

scn :: Parser ()
scn = L.space space1 lineComment multilineComment

sc :: Parser ()
sc =
  L.space
    (void (char (' ') <|> char '\t'))
    lineComment
    multilineComment

isReal :: (Num a, RealFrac a) => a -> Bool
isReal x = (ceiling x :: Integer) == floor x

consumeIndents :: Parser Int
consumeIndents = do
  -- Optionally consuming spaces and tabs
  ilevel <-
    optional $
      ( ( do
            sp <- howMany1 (char ' ')

            tabWidth <- readIORef tabWidthRef

            -- If the number of spaces is divisible by tab width then it is a valid
            -- indentation and we can return the number of tabs. Otherwise, we return
            -- the nearest integer value of the division of spaces by tab width.
            case tabWidth of
              Just tw -> do
                if isReal (fromIntegral sp / fromIntegral tw :: Double)
                  then return $ sp `div` tw
                  else fail $ "Indentation level mismatch, tab width should be equal to " ++ show tw ++ " but received " ++ show sp
              Nothing -> do
                writeIORef tabWidthRef (Just sp)
                return sp
        )
          <|> howMany1 (char '\t')
      )
        <* try indentSc

  -- If the indentation is not present, we return 0, basically meaning that
  -- this line is not indented.
  let processedIndent = case ilevel of
        Just i -> i
        Nothing -> 0

  -- Storing the current processed indent in the state
  writeIORef indentation processedIndent
  return processedIndent

reservedWords :: [Text]
reservedWords =
  [ "in"
  , "if"
  , "then"
  , "else"
  , "true"
  , "false"
  , "except"
  , "require"
  ]

-- Tab width for the indent sensitive parser
-- Defaulting to Nothing, meaning that the tab width is not set
-- It is set on first space or tab consumption
tabWidthRef :: IORef (Maybe Int)
tabWidthRef = unsafePerformIO $ newIORef Nothing

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: Text -> Parser Text
symbol = lexeme . L.symbol sc

reserved :: Text -> Parser Text
reserved keyword = do
  r <- lexeme (string keyword <* notFollowedBy alphaNumChar)
  -- Guarding parsed result here lets the parser building more security
  -- on top of the language definition.
  guard (r `elem` reservedWords)
  return r

parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

brackets :: Parser a -> Parser a
brackets = between (symbol "[") (symbol "]")

angles :: Parser a -> Parser a
angles = between (symbol "<") (symbol ">")

braces :: Parser a -> Parser a
braces = between (symbol "{") (symbol "}")

comma :: Parser Text
comma = symbol ","

colon :: Parser Text
colon = symbol ":"

identifier :: Parser Text
identifier = do
  r <- pack <$> lexeme ((:) <$> (letterChar <|> oneOf ("_" :: String)) <*> many (alphaNumChar <|> oneOf ("_" :: String)))
  -- Guarding parsed result and failing when reserved word is parsed
  -- (such as reserved keyword)
  guard (r `notElem` reservedWords) <?> "variable name"
  return r

-- How many times a parser can be applied. It returns the number of
-- times the parser was applied.
howMany :: Parser a -> Parser Int
howMany p = length <$> many p

-- howMany variant that requires at least one application of the parser
howMany1 :: Parser a -> Parser Int
howMany1 p = length <$> some p

-- Indent parser takes a parser and applies it only and only if the
-- indentation level is greater than the current indentation level.
-- It returns a list of parsed results with the same indentation level.
indent :: Parser a -> Parser [a]
indent p = do
  ilevel <- readIORef indentation
  level <- eol >> consumeIndents
  if level > ilevel
    then do
      x <- p
      xs <- many $ indentSame level p
      return (x : xs)
    else return []

indentSepBy :: Parser a -> Parser b -> Parser [a]
indentSepBy p sep = do
  ilevel <- readIORef indentation
  level <- eol >> consumeIndents
  if level > ilevel
    then do
      x <- p <* sep
      xs <- many $ indentSame level (p <* sep)
      end <- indentSame level p
      return (x : xs ++ [end])
    else return []

-- Indent parser that takes a parser and applies it only and only if the
-- indentation level is equal to the current indentation level.
-- If it's not, then it returns Nothing
indentSameOrNothing :: Int -> Parser a -> Parser (Maybe a)
indentSameOrNothing = (optional <$>) . indentSame

-- Indent parser that takes a parser and applies it only and only if the
-- indentation level is equal to the current indentation level or on the
-- same line
indentSameOrInline :: Int -> Parser a -> Parser a
indentSameOrInline ilevel p = indentSame ilevel p <|> p

-- Indent parser that takes a parser and applies it only and only if the
-- indentation level is equal to the current indentation level
-- It fails if the indentation level is not the same
indentSame :: Int -> Parser a -> Parser a
indentSame ilevel p = try $ do
  level <- indentSc *> consumeIndents
  if level == ilevel
    then p
    else fail $ "Indentation level mismatch, expected " ++ show ilevel ++ " but received " ++ show level

-- Indent parser that takes a parser and applies it only and only if there is
-- no indentation.
-- This indent sensitive parsing function is quite special as it does not
-- consume any newlines. Often used to parse top-level constructs.
nonIndented :: Parser a -> Parser a
nonIndented p = do
  ilevel <- consumeIndents
  if ilevel == 0
    then p
    else fail $ "Indentation level mismatch, expected 0 but received " ++ show ilevel
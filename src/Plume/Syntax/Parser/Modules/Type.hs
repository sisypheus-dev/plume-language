module Plume.Syntax.Parser.Modules.Type where

import Control.Monad.Parser
import Plume.Syntax.Common.Type
import Plume.Syntax.Parser.Lexer
import Text.Megaparsec
import Text.Megaparsec.Char

-- Primitive types parsing function
-- Primitive types are just types that are not using other types
-- to build themselves. They're final types as they can't be destructured.
tPrimitive :: Parser PlumeType
tPrimitive =
  choice
    [ symbol "int" $> TInt
    , symbol "bool" $> TBool
    , symbol "str" $> TString
    , symbol "char" $> TChar
    , symbol "float" $> TFloat
    ]

-- (t1, t2, ..., tn) -> ret where t1, t2, ..., tn are the function type arguments types
-- and ret is the function type return type
tFunction :: Parser PlumeType
tFunction = do
  args <- parens (tType `sepBy` comma)
  _ <- symbol "->"
  TFunction args <$> tType

-- (t1, t2, ..., tn) where t1, t2, ..., tn are the tuple type elements. There are tuple
-- special cases depending on the quantity of types specified for the tuple:
-- - Tuples with 0 argument are just unit, void types (as Haskell does)
-- - Tuples with 1 argument are just parenthesized types
-- - Tuples with n elements are real tuples
tTuple :: Parser PlumeType
tTuple = do
  tys <- parens (tType `sepBy` comma)
  return $
    case tys of
      [] -> TUnit
      [x] -> x
      _ -> TTuple tys

-- [t] where t is a concrete type. It represents list where the list's elements
-- are of t's type
tList :: Parser PlumeType
tList =
  TList <$> brackets tType

-- 'a where a is an identifier is used in order to build type variables (the most basic
-- type component used to deal with generic programming)
tVar :: Parser PlumeType
tVar = char '\'' *> (TVar <$> identifier)

-- x<t1, t2, ..., tn> where x is an identifier (resp. datatype name) and t1, t2, ... tn
-- are the datatype arguments. This is used to represent type applications over user-defined
-- datatypes (such as ADTs, or even GADTs...)
tCon :: Parser PlumeType
tCon = do
  c <- identifier
  tys <- angles (tType `sepBy1` comma)
  return (TCon c tys)

tId :: Parser PlumeType
tId = TId <$> identifier

data TypeRow
  = TypeField Text PlumeType
  | TypeExt PlumeType

orderTypeRows :: [TypeRow] -> ([(Text, PlumeType)], Maybe PlumeType)
orderTypeRows = foldl' f ([], Nothing)
 where
  f (acc, r) (TypeField l t) = (acc ++ [(l, t)], r)
  f (acc, _) (TypeExt t) = (acc, Just t)

buildFinalRecord :: [(Text, PlumeType)] -> Maybe PlumeType -> PlumeType
buildFinalRecord fields r =
  TRecord $
    foldl'
      (\acc (l, t) -> TRowExtend l t acc)
      (fromMaybe TRowEmpty r)
      fields

-- {l1: t1, l2: t2, ..., ln: tn | r} where l1, l2, ..., ln are the record
-- fields and t1, t2, ..., tn are the record fields types. r type is optional
-- and it represents the rest of the record fields. This is used to represent
-- record types.
tRecord :: Parser PlumeType
tRecord = braces $ do
  (fields, ext) <-
    orderTypeRows
      <$> sepBy
        ( ( do
              l <- identifier
              _ <- colon
              TypeField l <$> tType
          )
            <|> (symbol "..." *> (TypeExt <$> tType))
        )
        comma

  return $ buildFinalRecord fields ext

-- Main type parsing function
tType :: Parser PlumeType
tType =
  choice
    [ tRecord
    , -- Try may be used here because function type starts with the same
      -- syntax as tuple
      try tFunction
    , tPrimitive
    , tList
    , tTuple
    , tVar
    , -- Try may be used here because type application starts with an identifier
      -- just like type identifier
      try tCon
    , tId
    ]

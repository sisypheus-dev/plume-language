module Plume.Syntax.Concrete.Literal where

-- Literals are the most basic form of expressions.
-- They are the most primary form of data in the langage, letting the user
-- express more concrete programs.

type Label = Text

data Literal
  = LInt Integer
  | LBool Bool
  | LString String
  | LChar Char
  | LFloat Double
  deriving (Eq)

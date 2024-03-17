module Plume.Compiler.ClosureConversion.Free where

import Data.Set qualified as S
import Plume.Compiler.ClosureConversion.Syntax

class Free a where
  free :: a -> S.Set Text

instance (Free a) => Free [a] where
  free = foldMap free

instance (Free a) => Free (Maybe a) where
  free = foldMap free

instance (Free a, Free b) => Free (a, b) where
  free (a, b) = free a <> free b

instance Free ClosedExpr where
  free (CEVar x) = S.singleton x
  free (CEApplication f args) = free f <> free args
  free (CELiteral _) = S.empty
  free (CEList es) = free es
  free (CEDeclaration x e1 e2) = S.insert x (free e1 <> free e2)
  free (CEConditionBranch e1 e2 e3) = free e1 <> free e2 <> free e3
  free (CESwitch e cases) = free e <> free cases
  free (CEReturn e) = free e
  free (CENativeFunction _ _) = S.empty
  free (CEDictionary es) = free es
  free (CEProperty e _) = free e

instance Free ClosedPattern where
  free (CPVariable x) = S.singleton x
  free (CPLiteral _) = S.empty
  free (CPConstructor _ ps) = free ps
  free CPWildcard = S.empty

instance Free ClosedStatement where
  free (CSExpr e) = free e
  free (CSReturn e) = free e
  free (CSBlock ss) = free ss
  free (CSDeclaration x e) = S.insert x (free e)

instance Free ClosedProgram where
  free (CPFunction n args e) = free e S.\\ (S.fromList args <> S.singleton n)
  free (CPStatement s) = free s
  free (CPExtFunction _ n args e) = free e S.\\ (S.fromList args <> S.singleton n)

instance (Free a) => Free (Map k a) where
  free = foldMap free

instance (Free a) => Free (IntMap a) where
  free = foldMap free

class Substitutable a where
  substitute :: (Text, ClosedExpr) -> a -> a

instance Substitutable ClosedExpr where
  substitute (name, expr) (CEVar x)
    | x == name = expr
    | otherwise = CEVar x
  substitute (name, expr) (CEApplication f args) =
    CEApplication (substitute (name, expr) f) (map (substitute (name, expr)) args)
  substitute (name, expr) (CEList es) = CEList (map (substitute (name, expr)) es)
  substitute _ (CELiteral l) = CELiteral l
  substitute (name, expr) (CEDeclaration x e1 e2) =
    CEDeclaration x (substitute (name, expr) e1) (substitute (name, expr) e2)
  substitute (name, expr) (CEConditionBranch e1 e2 e3) =
    CEConditionBranch
      (substitute (name, expr) e1)
      (substitute (name, expr) e2)
      (substitute (name, expr) e3)
  substitute (name, expr) (CESwitch e cases) =
    CESwitch (substitute (name, expr) e) (map proceed cases)
   where
    proceed (p, e') = (p, substitute (name, expr) e')
  substitute (name, expr) (CEReturn e) = CEReturn (substitute (name, expr) e)
  substitute _ (CENativeFunction n gens) = CENativeFunction n gens
  substitute (name, expr) (CEDictionary es) = CEDictionary (fmap (substitute (name, expr)) es)
  substitute (name, expr) (CEProperty e i) = CEProperty (substitute (name, expr) e) i

instance Substitutable ClosedStatement where
  substitute e (CSBlock es) = CSBlock (map (substitute e) es)
  substitute e (CSExpr e') = CSExpr (substitute e e')
  substitute e (CSReturn e') = CSReturn (substitute e e')
  substitute (name, expr) (CSDeclaration x e) =
    CSDeclaration x (substitute (name, expr) e)

instance Substitutable ClosedProgram where
  substitute e (CPStatement s) = CPStatement (substitute e s)
  substitute e (CPFunction name args body) =
    CPFunction name args (substitute e body)
  substitute e (CPExtFunction t name args body) =
    CPExtFunction t name args (substitute e body)

instance Substitutable ClosedPattern where
  substitute _ p = p

substituteMany :: (Substitutable a) => [(Text, ClosedExpr)] -> a -> a
substituteMany = foldr ((.) . substitute) id
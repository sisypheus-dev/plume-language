module Plume.Syntax.Translation.Substitution where

import Data.Foldable
import Data.Set qualified as S
import Plume.Syntax.Abstract qualified as AST
import Plume.Syntax.Common qualified as AST

class Free a where
  ftv :: a -> Set Text

instance Free (AST.Annotation a) where
  ftv (AST.Annotation t _) = S.singleton t

instance Free AST.Pattern where
  ftv (AST.PVariable t) = S.singleton t
  ftv AST.PWildcard = S.empty
  ftv (AST.PLiteral _) = S.empty
  ftv (AST.PConstructor _ ps) = foldMap ftv ps

instance (Free a) => Free [a] where
  ftv = foldr (S.union . ftv) S.empty

substitute :: (Text, AST.Expression) -> AST.Expression -> AST.Expression
substitute (name, expr) (AST.EVariable n)
  | n == name = expr
  | otherwise = AST.EVariable n
substitute _ (AST.ELiteral l) = AST.ELiteral l
substitute (name, expr) (AST.EApplication e es) =
  AST.EApplication (substitute (name, expr) e) (map (substitute (name, expr)) es)
substitute (name, expr) (AST.EDeclaration g ann e me) =
  AST.EDeclaration
    g
    ann
    (substitute (name, expr) e)
    (fmap (substitute (name, expr)) me)
substitute (name, expr) (AST.EConditionBranch e1 e2 e3) =
  AST.EConditionBranch
    (substitute (name, expr) e1)
    (substitute (name, expr) e2)
    (substitute (name, expr) <$> e3)
substitute (name, expr) (AST.EClosure anns t e)
  | name `S.notMember` ftv anns = AST.EClosure anns t (substitute (name, expr) e)
  | otherwise = AST.EClosure anns t e
substitute (name, expr) (AST.EBlock es) = AST.EBlock (map (substitute (name, expr)) es)
substitute (name, expr) (AST.ELocated e p) = AST.ELocated (substitute (name, expr) e) p
substitute (name, expr) (AST.ESwitch e ps) =
  AST.ESwitch
    (substitute (name, expr) e)
    (map proceed ps)
 where
  proceed (p, e')
    | name `S.notMember` ftv p = (p, substitute (name, expr) e')
    | otherwise = (p, e')
substitute (name, expr) (AST.EReturn e) = AST.EReturn (substitute (name, expr) e)
substitute (name, expr) (AST.ETypeExtension g ann ems)
  | name `S.notMember` ftv ann =
      AST.ETypeExtension g ann (map (substituteExt (name, expr)) ems)
  | otherwise = AST.ETypeExtension g ann ems
substitute _ (AST.ENativeFunction fp n gens t) =
  AST.ENativeFunction fp n gens t
substitute _ (AST.EGenericProperty g n ts t) =
  AST.EGenericProperty g n ts t
substitute e (AST.EList es) = AST.EList (map (substitute e) es)
substitute _ (AST.EType ann ts) = AST.EType ann ts

substituteExt
  :: (Text, AST.Expression)
  -> AST.ExtensionMember AST.PlumeType
  -> AST.ExtensionMember AST.PlumeType
substituteExt (name, expr) (AST.ExtDeclaration g ann e)
  | name `S.notMember` ftv ann =
      AST.ExtDeclaration g ann (substitute (name, expr) e)
  | otherwise = AST.ExtDeclaration g ann e

substituteMany :: [(Text, AST.Expression)] -> AST.Expression -> AST.Expression
substituteMany xs e = foldl (flip substitute) e xs

substituteManyBlock
  :: [(Text, AST.Expression)] -> [AST.Expression] -> [AST.Expression]
substituteManyBlock = map . substituteMany

{-# LANGUAGE LambdaCase #-}

module Plume.Compiler.Desugaring.Modules.Switch where

import Data.Map qualified as M
import Plume.Compiler.ClosureConversion.Free
import Plume.Compiler.ClosureConversion.Syntax qualified as Pre
import Plume.Compiler.Desugaring.Monad
import Plume.Compiler.Desugaring.Syntax qualified as Post
import Plume.Syntax.Common.Literal

type Desugar' =
  Desugar Pre.ClosedStatement [ANFResult (Maybe Post.DesugaredStatement)]

type Desugar'' = Desugar Pre.ClosedExpr (ANFResult Post.DesugaredExpr)
type DesugarSwitch =
  (Desugar'', Desugar') -> Desugar''

desugarSwitch :: DesugarSwitch
desugarSwitch (fExpr, _) (Pre.CESwitch x cases) = do
  (x', stmts) <- fExpr x
  let (conds, maps) = unzip $ map (createCondition x' . fst) cases

  let bodies = map snd cases
  let cases' = zip3 [0 ..] bodies maps

  res <-
    mapM
      ( \case
          (i, expr, m) -> do
            let pat = maybeAt i conds
            (expr', stmts'') <- fExpr expr
            let stmts''' = substituteMany (M.toList m) (stmts'' <> [Post.DSReturn expr'])
            case pat of
              Just conds_ -> do
                let cond = createConditionExpr conds_
                return [Post.DSConditionBranch cond stmts''' []]
              Nothing ->
                return stmts'''
      )
      cases'
  let ifs' = createIfsStatement $ concat res

  return (Post.DEVar "nil", stmts <> ifs')
desugarSwitch _ _ = error "test"

createConditionExpr :: [Post.DesugaredExpr] -> Post.DesugaredExpr
createConditionExpr [] = Post.DELiteral (LBool True)
createConditionExpr [x] = x
createConditionExpr (x : xs) = Post.DEAnd x (createConditionExpr xs)

createIfsStatement
  :: [Post.DesugaredStatement]
  -> [Post.DesugaredStatement]
createIfsStatement [] = []
createIfsStatement (Post.DSConditionBranch c t [] : xs)
  | c == Post.DELiteral (LBool True) = t
  | otherwise = [Post.DSConditionBranch c t (createIfsStatement xs)]
createIfsStatement _ = error "test"

createIfs
  :: [([Post.DesugaredExpr], Post.DesugaredExpr)] -> Post.DesugaredExpr
createIfs [x] = snd x
createIfs ((cond, body) : xs) =
  if cond' == Post.DELiteral (LBool True)
    then body
    else Post.DEIf cond' body (createIfs xs)
 where
  cond' = createConditionExpr cond
createIfs [] = error "test"

createLets :: Map Text Post.DesugaredExpr -> [Post.DesugaredStatement]
createLets = M.foldrWithKey (\k v acc -> Post.DSDeclaration k v : acc) []

createCondition
  :: Post.DesugaredExpr
  -> Pre.ClosedPattern
  -> ([Post.DesugaredExpr], Map Text Post.DesugaredExpr)
createCondition _ Pre.CPWildcard = ([], mempty)
createCondition x (Pre.CPVariable y) = ([], M.singleton y x)
createCondition x (Pre.CPConstructor y xs) =
  let spc = Post.DEEqualsTo (Post.DEProperty x 0) Post.DESpecial
      cons = Post.DEEqualsTo (Post.DEProperty x 2) (Post.DELiteral (LString y))
      (conds, maps) = unzip $ zipWith (createCondition . Post.DEProperty x) [3 ..] xs
   in (spc : cons : concat conds, mconcat maps)
createCondition x (Pre.CPLiteral l) =
  ([Post.DEEqualsTo x (Post.DELiteral l)], mempty)
createCondition _ (Pre.CPSpecialVar _) = error "test"
{-# LANGUAGE LambdaCase #-}

module Plume.Syntax.Translation.ConcreteToAbstract where

import Plume.Syntax.Abstract qualified as AST
import Plume.Syntax.Concrete qualified as CST

import Control.Monad.Exception
import Plume.Syntax.Translation.ConcreteToAbstract.MacroResolver
import Plume.Syntax.Translation.ConcreteToAbstract.Operations
import Plume.Syntax.Translation.ConcreteToAbstract.Require
import Plume.Syntax.Translation.ConcreteToAbstract.UFCS
import Plume.Syntax.Translation.Generics
import System.Directory

interpretSpreadable
  :: Spreadable [AST.Expression] AST.Expression -> AST.Expression
interpretSpreadable (Single e) = e
interpretSpreadable (Spread [e]) = e
interpretSpreadable (Spread es) = AST.EBlock es
interpretSpreadable Empty = AST.EBlock []

concreteToAbstract
  :: CST.Expression
  -> TranslatorReader Error AST.Expression
concreteToAbstract (CST.EVariable n) = transRet . Right $ AST.EVariable n
concreteToAbstract (CST.ELiteral l) = transRet . Right $ AST.ELiteral l
concreteToAbstract e@(CST.EBinary {}) = convertOperation concreteToAbstract e
concreteToAbstract e@(CST.EPrefix {}) = convertOperation concreteToAbstract e
concreteToAbstract e@(CST.EApplication (CST.EProperty _ _) _) =
  convertUFCS concreteToAbstract e
concreteToAbstract (CST.EApplication e es) = do
  -- Checking if the first expression is alone, meaning that it is not
  -- composed of multiple elements (like a spread element), and unwraping
  -- Spreadable if it is.
  e' <- shouldBeAlone <$> concreteToAbstract e
  es' <- fmap flat . sequence <$> mapM concreteToAbstract es
  transRet $ AST.EApplication <$> e' <*> es'
concreteToAbstract (CST.EDeclaration ann e me) = do
  -- Declaration and body value cannot be spread elements, so we need to
  -- check if they are alone and unwrap them if they are.
  e' <- shouldBeAlone <$> concreteToAbstract e
  me' <- mapM shouldBeAlone <$> maybeM concreteToAbstract me
  transRet $ AST.EDeclaration ann <$> e' <*> me'
concreteToAbstract (CST.EConditionBranch e1 e2 e3) = do
  -- A condition should be a single expression
  e1' <- shouldBeAlone <$> concreteToAbstract e1

  -- But the branches can be spread elements, so we need to check if they
  -- are, and then combine them into a single expression by wrapping them
  -- into a block.
  e2' <- fmap interpretSpreadable <$> concreteToAbstract e2
  e3' <-
    fmap (fmap interpretSpreadable) . sequence <$> maybeM concreteToAbstract e3
  transRet $ AST.EConditionBranch <$> e1' <*> e2' <*> e3'
concreteToAbstract (CST.EClosure anns t e) = do
  -- Same method as described for condition branches
  e' <- fmap interpretSpreadable <$> concreteToAbstract e
  transRet $ AST.EClosure anns t <$> e'
concreteToAbstract (CST.EBlock es) = do
  -- Blocks can be composed of spread elements, so we need to flatten
  -- the list of expressions into a single expression.
  es' <-
    fmap flat . sequence <$> do
      oldMacroSt <- readIORef macroState
      res <- mapM concreteToAbstract es
      writeIORef macroState oldMacroSt
      return res
  transRet $ AST.EBlock <$> es'
concreteToAbstract r@(CST.ERequire _) =
  convertRequire concreteToAbstract r
concreteToAbstract (CST.ELocated e p) = do
  old <- readIORef positionRef
  writeIORef positionRef (Just p)

  res <-
    concreteToAbstract e `with` \case
      Single e' -> bireturn (Single (AST.ELocated e' p))
      Spread es -> bireturn (Spread es)
      Empty -> bireturn Empty

  writeIORef positionRef old
  return res
concreteToAbstract m@(CST.EMacro {}) =
  convertMacro concreteToAbstract m
concreteToAbstract m@(CST.EMacroFunction {}) =
  convertMacro concreteToAbstract m
concreteToAbstract m@(CST.EMacroVariable _) =
  convertMacro concreteToAbstract m
concreteToAbstract m@(CST.EMacroApplication {}) =
  convertMacro concreteToAbstract m
concreteToAbstract (CST.ESwitch e ps) = do
  -- Same method as described for condition branches
  e' <- shouldBeAlone <$> concreteToAbstract e
  ps' <-
    mapM sequence
      <$> mapM
        (\(p, body) -> (p,) . fmap interpretSpreadable <$> concreteToAbstract body)
        ps
  transRet $ AST.ESwitch <$> e' <*> ps'
concreteToAbstract (CST.EProperty {}) = do
  pos <- readIORef positionRef
  throwError $ case pos of
    Just p -> CompilerError $ "Unexpected property at " <> show p
    Nothing -> CompilerError "Unexpected property"
concreteToAbstract (CST.EReturn e) = do
  -- Return can be a spread element, so we need to check if it is and
  -- then combine the expressions into a single expression by wrapping
  -- them into a block.
  e' <- fmap interpretSpreadable <$> concreteToAbstract e
  transRet $ AST.EReturn <$> e'

runConcreteToAbstract :: [CST.Expression] -> IO (Either Error [AST.Expression])
runConcreteToAbstract x = do
  -- Getting the current working directory as a starting point
  -- for the reader monad
  cwd <- getCurrentDirectory

  runReaderT (fmap flat . sequence <$> mapM concreteToAbstract x) cwd

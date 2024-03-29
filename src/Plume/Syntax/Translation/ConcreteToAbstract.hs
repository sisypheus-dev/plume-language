{-# LANGUAGE LambdaCase #-}

module Plume.Syntax.Translation.ConcreteToAbstract where

import Control.Monad.Exception
import Data.List qualified as L
import Data.Text qualified as T
import Plume.Syntax.Abstract qualified as AST
import Plume.Syntax.Common qualified as Common
import Plume.Syntax.Concrete qualified as CST
import Plume.Syntax.Translation.ConcreteToAbstract.MacroResolver
import Plume.Syntax.Translation.ConcreteToAbstract.Operations
import Plume.Syntax.Translation.ConcreteToAbstract.Require
import Plume.Syntax.Translation.ConcreteToAbstract.UFCS
import Plume.Syntax.Translation.Generics
import System.Directory
import System.FilePath

interpretSpreadable
  :: Spreadable [AST.Expression] AST.Expression -> AST.Expression
interpretSpreadable (Single e) = e
interpretSpreadable (Spread [e]) = e
interpretSpreadable (Spread es) = AST.EBlock es
interpretSpreadable Empty = AST.EBlock []

spanProperty
  :: CST.Expression -> Maybe (CST.Expression -> CST.Expression, CST.Expression)
spanProperty = go
 where
  go :: CST.Expression -> Maybe (CST.Expression -> CST.Expression, CST.Expression)
  go (CST.EProperty e p) = Just (id, CST.EProperty e p)
  go (CST.ELocated e p) = Just ((`CST.ELocated` p), e)
  go _ = Nothing

concreteToAbstract
  :: CST.Expression
  -> TranslatorReader Error AST.Expression
concreteToAbstract (CST.EVariable n) = transRet . Right $ AST.EVariable n
concreteToAbstract (CST.ELiteral l) = transRet . Right $ AST.ELiteral l
concreteToAbstract e@(CST.EBinary {}) = convertOperation concreteToAbstract e
concreteToAbstract e@(CST.EPrefix {}) = convertOperation concreteToAbstract e
concreteToAbstract (CST.EApplication e args)
  | Just (_, e') <- spanProperty e = do
      convertUFCS concreteToAbstract (CST.EApplication e' args)
  | otherwise = do
      e' <- shouldBeAlone <$> concreteToAbstract e
      es' <- fmap flat . sequence <$> mapM concreteToAbstract args
      transRet $ AST.EApplication <$> e' <*> es'
concreteToAbstract (CST.EDeclaration g ann e me) = do
  -- Declaration and body value cannot be spread elements, so we need to
  -- check if they are alone and unwrap them if they are.
  e' <- shouldBeAlone <$> concreteToAbstract e
  me' <- mapM shouldBeAlone <$> maybeM concreteToAbstract me
  transRet $ AST.EDeclaration g ann <$> e' <*> me'
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
concreteToAbstract (CST.ETypeExtension g ann ems) = do
  ems' <-
    fmap flat . sequence <$> mapM concreteToAbstractExtensionMember ems
  transRet $ AST.ETypeExtension g ann <$> ems'
concreteToAbstract (CST.ENativeFunction fp n gens t) = do
  let strModName = toString fp
  let isStd = "std:" `T.isPrefixOf` fp
  cwd <- ask
  let modPath =
        if isStd
          then do
            p <- liftIO $ readIORef stdPath
            case p of
              Just p' -> return $ Right (p' </> drop 4 strModName)
              Nothing -> throwError' $ CompilerError "Standard library path not set"
          else return $ Right (cwd </> strModName)
  modPath `with` \path -> do
    liftIO (doesFileExist path) >>= \case
      False -> do
        pos <- readIORef positionRef
        throwError $ case pos of
          Just p -> ModuleNotFound fp p
          Nothing -> NoPositionSaved
      _ -> transRet . Right $ AST.ENativeFunction (fromString path) n gens t
concreteToAbstract (CST.EGenericProperty g n ts t) =
  transRet . Right $ AST.EGenericProperty g n ts t
concreteToAbstract (CST.EList es) = do
  -- Lists can be composed of spread elements, so we need to flatten
  -- the list of expressions into a single expression.
  es' <-
    fmap flat . sequence <$> mapM concreteToAbstract es
  transRet $ AST.EList <$> es'
concreteToAbstract (CST.EType ann ts) = do
  bireturn . Single $ AST.EType ann ts

concreteToAbstractExtensionMember
  :: CST.ExtensionMember Common.PlumeType
  -> TranslatorReader Error (AST.ExtensionMember Common.PlumeType)
concreteToAbstractExtensionMember (CST.ExtDeclaration g ann e) = do
  e' <- shouldBeAlone <$> concreteToAbstract e
  return $ Single . AST.ExtDeclaration g ann <$> e'

runConcreteToAbstract
  :: Maybe FilePath
  -> FilePath
  -> [CST.Expression]
  -> IO (Either Error [AST.Expression])
runConcreteToAbstract std dir x = do
  writeIORef stdPath std
  -- Getting the current working directory as a starting point
  -- for the reader monad
  cwd <- (</> dir) <$> getCurrentDirectory

  runReaderT
    ( do
        let x' = loadPrelude std x
        fmap (L.nub . flat) . sequence <$> mapM concreteToAbstract x'
    )
    cwd

loadPrelude :: Maybe FilePath -> [CST.Expression] -> [CST.Expression]
loadPrelude (Just path) = do
  let preludePath = path </> "prelude"
  let require = CST.ERequire (fromString preludePath)
  (require :)
loadPrelude Nothing = id
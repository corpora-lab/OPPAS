{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TemplateHaskell #-}
{- |
   Module      : Pomc.Z3Encoding
   Copyright   : 2020-2025 Michele Chiari
   License     : MIT
   Maintainer  : Michele Chiari
-}

module Pomc.Z3Encoding ( SMTOpts(..)
                       , defaultSmtOpts
                       , SMTStatus(..)
                       , SMTResult(..)
                       , TableauNode(..)
                       , isSatisfiable
                       , modelCheckProgram
                       ) where

import Prelude hiding (take, pred)

import Pomc.Prop (Prop(..))
import Pomc.Potl (Dir(..), Formula(..), pnf, atomic)
import Pomc.Prec (Prec(..), Alphabet, isComplete)
import Pomc.TimeUtils (startTimer, stopTimer, timeAction, timeActionAcc)
import Pomc.LogUtils (LogVerbosity, selectLogVerbosity)
import qualified Pomc.MiniProc as MP
import qualified Pomc.MiniIR as MP

import Z3.Monad hiding (Result(..))
import qualified Z3.Monad as Z3

import qualified Control.Exception as E
import Control.Monad ((<=<), filterM)
import Control.Monad.Logger (MonadLogger, logInfo, logDebugSH)
import Data.List ((\\), intercalate, singleton)
import Data.Bits (finiteBitSize, countLeadingZeros)
import Data.Map.Lazy (Map)
import qualified Data.Map.Lazy as M
import qualified Data.Set as S
import Data.Maybe (isJust, isNothing, fromJust)
import Data.Word (Word64)
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.BitVector as BV
import qualified Data.Text as T

-- import qualified Debug.Trace as DBG

data SMTOpts = SMTOpts { smtMaxDepth       :: Word64
                       , smtVerbose        :: LogVerbosity
                       , smtComplete       :: Bool
                       , smtFastEmpty      :: Bool
                       , smtFastPrune      :: Bool
                       , smtUseArrayTheory :: Bool
                       }

defaultSmtOpts :: Word64 -> SMTOpts
defaultSmtOpts maxDepth = SMTOpts { smtMaxDepth  = maxDepth
                                  , smtVerbose   = Nothing
                                  , smtComplete  = True
                                  , smtFastEmpty = True
                                  , smtFastPrune = False
                                  , smtUseArrayTheory = False
                                  }

data SMTStatus = Sat | Unsat | Unknown deriving (Eq, Ord, Show)

data TableauNode = TableauNode { nodeGammaC :: [Formula MP.ExprProp]
                               , nodeSmb    :: Prop MP.ExprProp
                               , nodeStack  :: Integer
                               , nodeCtx    :: Integer
                               , nodeIdx    :: Integer
                               } deriving Eq

data SMTResult = SMTResult { smtStatus     :: SMTStatus
                           , smtTableau    :: Maybe [TableauNode]
                           , smtTimeAssert :: Double
                           , smtTimeCheck  :: Double
                           , smtTimeModel  :: Double
                           } deriving (Eq, Show)

instance Show TableauNode where
  show tn = "(" ++ (intercalate ", " [ show $ nodeIdx tn
                                     , show $ nodeGammaC tn
                                     , "smb = " ++ show (nodeSmb tn)
                                     , "stack = " ++ show (nodeStack tn)
                                     , "ctx = " ++ show (nodeCtx tn)
                                     ]) ++ ")"

data Query = SatQuery { qAlphabet :: Alphabet MP.ExprProp }
           | MiniProcQuery { qProg :: MP.Program }
           deriving Show

isSatisfiable :: SMTOpts
              -> Alphabet String
              -> Formula String
              -> IO SMTResult
isSatisfiable smtopts alphabet phi =
  checkQuery smtopts epPhi (SatQuery epAlphabet)
  where
    epPhi = fmap (MP.TextProp . T.pack) phi
    epAlphabet = MP.stringToExprPropAlphabet alphabet

modelCheckProgram :: SMTOpts -> Formula MP.ExprProp -> MP.Program -> IO SMTResult
modelCheckProgram smtopts phi prog = do
  res <- checkQuery (smtopts { smtFastEmpty = False }) (Not phi) (MiniProcQuery prog)
  -- fastEmpty leads to false positives with programs
  return res { smtStatus = flipStatus $ smtStatus res }
  where flipStatus Sat = Unsat
        flipStatus Unsat = Sat
        flipStatus Unknown = Unknown

checkQuery :: SMTOpts
           -> Formula MP.ExprProp
           -> Query
           -> IO SMTResult
checkQuery smtopts phi query =
  evalZ3With (if smtUseArrayTheory smtopts then Nothing else Just QF_UFBV) stdOpts
  $ selectLogVerbosity (smtVerbose smtopts)
  $ do
  reset
  t0 <- startTimer
  encData <- initPhiEncoding pnfPhi alphabet maxDepth
  maybeProgData <- case query of
    SatQuery {} -> return Nothing
    MiniProcQuery prog -> Just <$> initProgEncoding (smtUseArrayTheory smtopts) encData prog
  initTime <- stopTimer t0 $ isJust maybeProgData
  if smtComplete smtopts
    then completeCheck encData maybeProgData initTime 0 1 minLength
    else partialCheck encData maybeProgData initTime 0 1 minLength
  where
    pnfPhi = pnf phi
    maxDepth = smtMaxDepth smtopts
    (minLength, alphabet) = case query of
      SatQuery a -> (1, a)
      MiniProcQuery _ -> (2, MP.miniProcAlphabet)

    completeCheck :: (MonadFail z3, MonadZ3 z3, MonadLogger z3)
                  => EncData -> Maybe ProgData
                  -> Double -> Double -> Word64 -> Word64
                  -> z3 SMTResult
    completeCheck encData maybeProgData assertTime0 checkTime0 from to
      | to > maxDepth = return SMTResult { smtStatus = Unknown
                                         , smtTableau = Nothing
                                         , smtTimeAssert = assertTime0
                                         , smtTimeCheck = checkTime0
                                         , smtTimeModel = 0
                                         }
      | otherwise = do
          $(logInfo) $ T.pack $ "Checking prefixes of length k = " ++ show to
          t0 <- startTimer
          assertPhiEncoding encData from to
          case maybeProgData of
            Just progData -> assertProgEncoding encData progData from to
            Nothing -> return ()
          assertPrune (smtFastPrune smtopts) encData maybeProgData to
          assertTime1 <- fmap (+ assertTime0) $ stopTimer t0 ()

          (res1, checkTime1) <- timeActionAcc checkTime0 (== Z3.Sat) solverCheck
          case res1 of
            Z3.Unsat -> do
              $(logInfo) $ T.pack $ "Unraveling is UNSAT (k = " ++ show to ++ ")"
              return SMTResult { smtStatus = Unsat
                               , smtTableau = Nothing
                               , smtTimeAssert = assertTime1
                               , smtTimeCheck = checkTime1
                               , smtTimeModel = 0
                               }
            Z3.Undef -> error "Z3 unexpectedly reported Undef"
            Z3.Sat -> do
              $(logDebugSH) =<< queryTableau encData to Nothing =<< solverGetModel
              -- DBG.traceM =<< showModel =<< solverGetModel

              t1 <- startTimer
              phiAssumptions <- mkPhiAssumptions (smtFastEmpty smtopts) encData to
              progAssumptions <- case maybeProgData of
                Just progData -> mkProgAssumptions encData progData to
                Nothing -> return []
              assertTime2 <- fmap (+ assertTime1) $ stopTimer t1 $ null progAssumptions

              (res2, checkTime2) <- timeActionAcc checkTime1 (== Z3.Sat)
                $ solverCheckAssumptions (phiAssumptions ++ progAssumptions)
              case res2 of
                Z3.Sat -> do
                  $(logInfo) $ T.pack $ "Assumptions are SAT (k = " ++ show to ++ ")"
                  t2 <- startTimer
                  model <- solverGetModel
                  tableau <- queryTableau encData to Nothing model
                  modelTime <- stopTimer t2 $ null tableau
                  return SMTResult { smtStatus = Sat
                                   , smtTableau = Just tableau
                                   , smtTimeAssert = assertTime2
                                   , smtTimeCheck = checkTime2
                                   , smtTimeModel = modelTime
                                   }
                Z3.Undef -> error "Z3 unexpectedly reported Undef"
                Z3.Unsat -> completeCheck encData maybeProgData
                            assertTime2 checkTime2
                            (to + 1) (to + 1)

    partialCheck :: (MonadFail z3, MonadZ3 z3)
                 => EncData -> Maybe ProgData
                 -> Double -> Double -> Word64 -> Word64
                 -> z3 SMTResult
    partialCheck encData maybeProgData assertTime checkTime from to
      | to > maxDepth = return SMTResult { smtStatus = Unknown
                                         , smtTableau = Nothing
                                         , smtTimeAssert = assertTime
                                         , smtTimeCheck = checkTime
                                         , smtTimeModel = 0
                                         }
      | otherwise = do
          t0 <- startTimer
          assertPhiEncoding encData from to
          phiAssumptions <- mkPhiAssumptions (smtFastEmpty smtopts) encData to
          progAssumptions <- case maybeProgData of
            Nothing -> return []
            Just progData -> assertProgEncoding encData (fromJust maybeProgData) from to
                             >> mkProgAssumptions encData progData to
          newAssertTime <- stopTimer t0 $ null progAssumptions

          (res, newCheckTime) <- timeAction (== Z3.Sat)
            $ solverCheckAssumptions (phiAssumptions ++ progAssumptions)
          if res == Z3.Sat
            then do
            t1 <- startTimer
            model <- solverGetModel
            tableau <- queryTableau encData to Nothing model
            modelTime <- stopTimer t1 $ null tableau
            return SMTResult { smtStatus = Sat
                             , smtTableau = Just tableau
                             , smtTimeAssert = assertTime + newAssertTime
                             , smtTimeCheck = checkTime + newCheckTime
                             , smtTimeModel = modelTime
                             }
            else partialCheck encData maybeProgData (assertTime + newAssertTime)
                 (checkTime + newCheckTime) (to + 1) (to + 1)


data EncData = EncData { zClos       :: [Formula MP.ExprProp]
                       , zStructClos :: [Formula MP.ExprProp]
                       , zNodeSort   :: Sort
                       , zSSort      :: Sort
                       , zFConstMap  :: Map (Formula MP.ExprProp) AST
                       , zGamma      :: FuncDecl
                       , zSigma      :: FuncDecl
                       , zStruct     :: FuncDecl
                       , zSmb        :: FuncDecl
                       , zYield      :: FuncDecl
                       , zEqual      :: FuncDecl
                       , zTake       :: FuncDecl
                       , zStack      :: FuncDecl
                       , zCtx        :: FuncDecl
                       , zPred       :: FuncDecl
                       }

initPhiEncoding :: MonadZ3 z3 => Formula MP.ExprProp -> Alphabet MP.ExprProp -> Word64 -> z3 EncData
initPhiEncoding phi alphabet k = do
  -- Sorts
  boolSort <- mkBoolSort
  nodeSortSymbol <- mkStringSymbol "NodeSort"
  nodeSort <- mkFiniteDomainSort nodeSortSymbol $ k + 1
  (sSort, fConstMap) <- mkSSort
  -- Uninterpreted functions
  gamma  <- mkFreshFuncDecl "gamma" [sSort, nodeSort] boolSort
  sigma  <- mkFreshFuncDecl "sigma" [sSort] boolSort
  struct <- mkFreshFuncDecl "struct" [nodeSort] sSort
  smb    <- mkFreshFuncDecl "smb" [nodeSort] sSort
  yield  <- mkFreshFuncDecl "yield" [sSort, sSort] boolSort
  equal  <- mkFreshFuncDecl "equal" [sSort, sSort] boolSort
  take   <- mkFreshFuncDecl "take" [sSort, sSort] boolSort
  stack  <- mkFreshFuncDecl "stack" [nodeSort] nodeSort
  ctx    <- mkFreshFuncDecl "ctx" [nodeSort] nodeSort
  pred   <- mkFreshFuncDecl "pred" [nodeSort] nodeSort
  -- Auxiliary encoding struct
  let encData = EncData
        { zClos       = clos
        , zStructClos = structClos
        , zNodeSort   = nodeSort
        , zSSort      = sSort
        , zFConstMap  = fConstMap
        , zGamma      = gamma
        , zSigma      = sigma
        , zStruct     = struct
        , zSmb        = smb
        , zYield      = yield
        , zEqual      = equal
        , zTake       = take
        , zStack      = stack
        , zCtx        = ctx
        , zPred       = pred
        }
  -- Encoding
  assert =<< mkPhiAxioms encData
  assert =<< mkPhiOPM encData

  -- struct(⊥) = smb(⊥) = #
  nodeBot <- mkUnsignedInt64 0 nodeSort -- Note: all quantifiers on nodes should exclude 0
  assert =<< mkApp gamma [fConstMap M.! Atomic End, nodeBot]
  assert =<< mkEq (fConstMap M.! Atomic End) =<< mkApp1 struct nodeBot
  assert =<< mkEq (fConstMap M.! Atomic End) =<< mkApp1 smb nodeBot
  -- stack(0) = ctx(0) = 0
  assert =<< mkEq nodeBot =<< mkApp1 stack nodeBot
  assert =<< mkEq nodeBot =<< mkApp1 ctx nodeBot
  assert =<< mkEndTerm encData nodeBot

  -- xnf(φ)(1)
  node1 <- mkUnsignedInt64 1 nodeSort
  assert =<< groundxnf encData phi node1

  -- smb(1) = #
  assert =<< mkEq (fConstMap M.! Atomic End) =<< mkApp1 smb node1
  -- stack(1) = ctx(1) = ⊥
  assert =<< mkEq nodeBot =<< mkApp1 stack node1
  assert =<< mkEq nodeBot =<< mkApp1 ctx node1

  -- Back is false and WBack is true in 1
  let holdsIn1 g = mkApp gamma [fConstMap M.! g, node1]
  assert =<< mkAndWith (mkNot <=< holdsIn1) [g | g@(Back _) <- clos]
  assert =<< mkAndWith holdsIn1 [g | g@(WBack _) <- clos]

  return encData
  where
    (structClos, clos) = closure alphabet phi

    mkSSort :: MonadZ3 z3 => z3 (Sort, Map (Formula MP.ExprProp) AST)
    mkSSort = do
      constructors <- mapM (\f -> do
                               let fstring = show f
                               constrName <- mkStringSymbol fstring
                               recFnName <- mkStringSymbol $ "is_" ++ fstring
                               mkConstructor constrName recFnName [])
                      clos
      sSymbol <- mkStringSymbol "S"
      sSort <- mkDatatype sSymbol constructors
      constrFns <- getDatatypeSortConstructors sSort
      consts <- mapM (flip mkApp []) constrFns
      return (sSort, M.fromList $ zip clos consts)

    mkPhiAxioms :: MonadZ3 z3 => EncData -> z3 AST
    mkPhiAxioms encData = do
      let fConstMap = zFConstMap encData
          sigma = zSigma encData
      -- ∧_(p∈Σ) Σ(p)
      allStructInSigma <- mkAndWith (mkApp1 sigma . (fConstMap M.!)) structClos
      -- ∧_(p∈S \ Σ) ¬Σ(p)
      allOtherNotInSigma <- mkAndWith (mkNot <=< mkApp1 sigma . (fConstMap M.!))
                            (clos \\ structClos)
      mkAnd [allStructInSigma, allOtherNotInSigma]

    mkPhiOPM :: MonadZ3 z3 => EncData -> z3 AST
    mkPhiOPM encData = E.assert (isComplete alphabet)
      $ mkAndWith assertPrecPair
      $ snd alphabet ++ (End, End, Equal):[(End, p, Yield) | p <- fst alphabet]
      where assertPrecPair (p, q, prec) = do
              let fConstMap = zFConstMap encData
                  pqArg = [fConstMap M.! Atomic p, fConstMap M.! Atomic q]
                  (nPrec1, nPrec2) = getNegPrec prec
              posPrec  <- mkApp (getPosPrec prec) pqArg
              negPrec1 <- mkNot =<< mkApp nPrec1 pqArg
              negPrec2 <- mkNot =<< mkApp nPrec2 pqArg
              mkAnd [posPrec, negPrec1, negPrec2]

            (yield, equal, take) = (zYield encData, zEqual encData, zTake encData)

            getPosPrec Yield = yield
            getPosPrec Equal = equal
            getPosPrec Take = take

            getNegPrec Yield = (equal, take)
            getNegPrec Equal = (yield, take)
            getNegPrec Take = (yield, equal)

-- END(x)
mkEndTerm :: MonadZ3 z3 => EncData -> AST -> z3 AST
mkEndTerm encData x = do
  let fConstMap = zFConstMap encData
      gamma = zGamma encData
      clos = zClos encData
      noGamma g = mkNot =<< mkApp gamma [fConstMap M.! g, x]
  -- Γ(#, x)
  gammaEndx <- mkApp gamma [fConstMap M.! Atomic End, x]
  -- ∧_(PNext t α ∈ Cl(φ)) ¬Γ((PNext t α)_G, x)
  -- ∧_(Next α ∈ Cl(φ)) ¬Γ((Next α)_G, x)
  -- ∧_(HNext t α ∈ Cl(φ)) ¬Γ((HNext t α)_G, x)
  -- ∧_(p ∈ AP) ¬Γ(p, x)
  noGammaAll <- mkAndWith noGamma
    (filter (\g -> case g of
                Atomic (Prop _) -> True
                PNext _ _ -> True
                Next _ -> True
                XNext _ _ -> True
                HNext _ _ -> True
                _ -> False
            ) clos)
  -- Final →
  mkImplies gammaEndx noGammaAll

assertPhiEncoding :: MonadZ3 z3 => EncData -> Word64 -> Word64 -> z3 ()
assertPhiEncoding encData from to = do
  let clos = zClos encData
      yield = zYield encData
      equal = zEqual encData
      take = zTake encData
      nodeSort = zNodeSort encData
  -- start ∀x (...)
  -- Rules with x <= k (centered on x)
  let leqRules = filter (not . null . fst)
                 [ ([g | g@(XNext _ _) <- clos], mkXnext)
                 , ([g | g@(WXNext _ _) <- clos], mkWxnext)
                 , ([g | g@(HUntil Up T T) <- clos], mkHuaux)
                 ]
      mkLeqRules x = do
        xLit <- mkUnsignedInt64 x nodeSort
        checkPushx <- mkCheckPrec encData yield xLit
        checkPopx <- mkCheckPrec encData take xLit
        -- PhiAxiom
        phiAxiom <- mkPhiAxiomsForall xLit
        endx <- mkEndTerm encData xLit
        conflictx <- mkConflict xLit
        leqRulesx <- mapM (\(allFs, mkRule) -> mkRule allFs x checkPushx checkPopx) leqRules
        mkAnd $ [phiAxiom, endx, conflictx] ++ leqRulesx
  assert =<< mkForallNodes [(max 1 from)..to] mkLeqRules

  -- Rules with x < k (centered on x-1)
  let ltRules = filter (not . null . fst)
                [ ([g | g@(PNext _ _) <- clos] ++ [g | g@(WPNext _ _) <- clos], mkPnext)
                , ([g | g@(HNext Up _) <- clos], mkHnextu)
                , ([g | g@(HNext Down _) <- clos], mkHnextd)
                , ([g | g@(WHNext Up _) <- clos], mkWhnextu)
                , ([g | g@(WHNext Down _) <- clos], mkWhnextd)
                , ([g | g@(HUntil Down T T) <- clos], mkHdaux)
                ]
      mkLtRules x = do
        xLit <- mkUnsignedInt64 x nodeSort
        checkPushx <- mkCheckPrec encData yield xLit
        checkShiftx <- mkCheckPrec encData equal xLit
        checkPopx <- mkCheckPrec encData take xLit
        -- push(x) → PUSH(x)
        pushxImpliesPushx <- mkImplies checkPushx =<< mkPush x
        -- shift(x) → SHIFT(x)
        shiftxImpliesShiftx <- mkImplies checkShiftx =<< mkShift x
        -- pop(x) → POP(x)
        popxImpliesPopx <- mkImplies checkPopx =<< mkPop x
        ltRulesx <- mapM (\(allFs, mkRule) -> mkRule allFs x checkPushx checkShiftx checkPopx) ltRules
        mkAnd $ [pushxImpliesPushx, shiftxImpliesShiftx, popxImpliesPopx] ++ ltRulesx
  assert =<< mkForallNodes [((max 2 from) - 1)..(to - 1)] mkLtRules
  -- end ∀x (...)
  where
    mkPhiAxiomsForall :: MonadZ3 z3 => AST -> z3 AST
    mkPhiAxiomsForall xLit = do
      let sigma = zSigma encData
      -- Σ(struct(x)) ∧ Σ(smb(x)) ∧ Γ(struct(x), x)
      structX <- mkApp1 (zStruct encData) xLit
      sigmaStructX <- mkApp1 sigma structX
      sigmaSmbX <- mkApp1 sigma =<< mkApp1 (zSmb encData) xLit
      gammaStructXX <- mkApp (zGamma encData) [structX, xLit]
      mkAnd [sigmaStructX, sigmaSmbX, gammaStructXX]

    -- CONFLICT(x)
    mkConflict :: MonadZ3 z3 => AST -> z3 AST
    mkConflict x = do
      structx <- mkApp1 (zStruct encData) x
      let structClos = zStructClos encData
          fConstMap = zFConstMap encData
          gamma = zGamma encData
          singleSl p = do
            structxEqp <- mkEq structx (fConstMap M.! p)
            noOtherSls <- mkAndWith (\q -> mkNot =<< mkApp gamma [fConstMap M.! q, x])
                          $ filter (/= p) structClos
            mkAnd [structxEqp, noOtherSls]
      mkOrWith singleSl structClos

    -- PNEXT(x) ∧ WPNEXT(x)
    mkPnext :: MonadZ3 z3 => [Formula MP.ExprProp] -> Word64 -> AST -> AST -> AST -> z3 AST
    mkPnext _ x checkPushx checkShiftx _ = do
      let clos = zClos encData
          fConstMap = zFConstMap encData
          gamma = zGamma encData
          struct = zStruct encData
      xLit <- mkUnsignedInt64 x $ zNodeSort encData
      xp1 <- mkUnsignedInt64 (x + 1) $ zNodeSort encData
      let pnextPrec prec g = do
            -- Γ(g, x)
            gammagx <- mkApp gamma [fConstMap M.! g, xLit]
            -- struct(x) prec struct(x + 1)
            structx <- mkApp1 struct xLit
            structxp1 <- mkApp1 struct xp1
            structPrec <- mkApp prec [structx, structxp1]
            -- Final negated and
            mkNot =<< mkAnd [gammagx, structPrec]
      -- ∧_(PNext d α ∈ Cl(φ)) (...)
      pnextDown <- mkAndWith (pnextPrec $ zTake encData) [g | g@(PNext Down _) <- clos]
      -- ∧_(PNext u α ∈ Cl(φ)) (...)
      pnextUp <- mkAndWith (pnextPrec $ zYield encData) [g | g@(PNext Up _) <- clos]
      let wpnextPrec prec (g, arg) = do
            -- Γ(g, x)
            gammagx <- mkApp gamma [fConstMap M.! g, xLit]
            -- Γ(h, x + 1)
            gammahxp1 <- groundxnf encData arg xp1
            -- struct(x) prec struct(x + 1)
            structx <- mkApp1 struct xLit
            structxp1 <- mkApp1 struct xp1
            structPrec <- mkApp prec [structx, structxp1]
            -- Final implication
            notStructPrec <- mkNot structPrec
            gammagxAndNotStructPrec <- mkAnd [gammagx, notStructPrec]
            mkImplies gammagxAndNotStructPrec gammahxp1
      wpnextDown <- mkAndWith (wpnextPrec $ zTake encData) [(g, arg) | g@(WPNext Down arg) <- clos]
      wpnextUp <- mkAndWith (wpnextPrec $ zYield encData) [(g, arg) | g@(WPNext Up arg) <- clos]
      inputx <- mkOr [checkPushx, checkShiftx]
      mkImplies inputx =<< mkAnd [pnextDown, pnextUp, wpnextDown, wpnextUp]

    -- XNEXT(x)
    mkXnext :: MonadZ3 z3 => [Formula MP.ExprProp] -> Word64 -> AST -> AST -> z3 AST
    mkXnext allXnext x _ checkPopx = do
      let nodeSort = zNodeSort encData
          struct = zStruct encData
          stack = zStack encData
          yield = zYield encData
          equal = zEqual encData
          take = zTake encData
      xLit <- mkUnsignedInt64 x nodeSort
      stackx <- mkApp1 stack xLit
      let allXnextSat y = do
            yLit <- mkUnsignedInt64 y nodeSort
            yInput <- mkNot =<< mkCheckPrec encData take yLit -- y is not a POP
            yPush <- mkEq stackx yLit -- y is the PUSH of stackx
            yShift <- mkEq stackx =<< mkApp1 stack yLit -- y is a SHIFT on stackx
            yStackCond <- mkOr [yPush, yShift]
            ySuppClosed <- mkAnd [yInput, yStackCond]

            structy <- mkApp1 struct yLit
            let xnextSat g@(XNext dir arg) = do
                  gammagy <- mkApp (zGamma encData) [zFConstMap encData M.! g, yLit]
                  let satisfied z = do
                        zLit <- mkUnsignedInt64 z nodeSort
                        checkPopz <- mkCheckPrec encData take zLit
                        ctxz <- mkApp1 (zCtx encData) zLit
                        ctxzEqy <- mkEq ctxz yLit
                        xnfArgz <- groundxnf encData arg zLit
                        structz <- mkApp1 struct zLit
                        precYT <- case dir of
                          Down -> mkApp yield [structy, structz]
                          Up   -> mkApp take [structy, structz]
                        precEq <- mkApp equal [structy, structz]
                        orPrec <- mkOr [precYT, precEq]
                        mkAnd [checkPopz, ctxzEqy, xnfArgz, orPrec]
                  exists <- mkExistsNodes [y..x] satisfied
                  mkImplies gammagy exists
                xnextSat _ = error "XNext formula expected."

            allSat <- mkAndWith xnextSat allXnext
            mkImplies ySuppClosed allSat

      mkImplies checkPopx =<< mkForallNodes [1..(x-1)] allXnextSat

    {- Iff version of mkWxnext
    mkWxnext2 :: Word64 -> Z3 AST
    mkWxnext2 x = do
      let nodeSort = zNodeSort encData
          struct = zStruct encData
          stack = zStack encData
          yield = zYield encData
          equal = zEqual encData
          take = zTake encData
      xLit <- mkUnsignedInt64 x nodeSort
      stackx <- mkApp1 stack xLit
      let allXnextSat y = do
            yLit <- mkUnsignedInt64 y nodeSort
            yPush <- mkEq stackx yLit -- y is the PUSH of stackx
            yShift <- mkEq stackx =<< mkApp1 stack yLit -- y is a SHIFT on stackx
            ySuppClosed <- mkOr [yPush, yShift]

            structy <- mkApp1 struct yLit
            let xnextSat g@(WXNext dir arg) = do
                  gammagy <- mkApp (zGamma encData) [zFConstMap encData M.! g, yLit]
                  let satisfied z = do
                        zLit <- mkUnsignedInt64 z nodeSort
                        checkPopz <- mkCheckPrec encData (zTake encData) zLit
                        ctxz <- mkApp1 (zCtx encData) zLit
                        ctxzEqy <- mkEq ctxz yLit
                        xnfArgz <- groundxnf encData arg zLit
                        structz <- mkApp1 struct zLit
                        precYT <- case dir of
                          Down -> mkApp yield [structy, structz]
                          Up   -> mkApp take [structy, structz]
                        precEq <- mkApp equal [structy, structz]
                        orPrec <- mkOr [precYT, precEq]
                        lhs <- mkAnd [checkPopz, ctxzEqy, orPrec]
                        mkImplies lhs xnfArgz
                  exists <- mkForallNodes [y..x] satisfied
                  mkEq gammagy exists
                xnextSat _ = error "XNext formula expected."

            allSat <- mkAndWith xnextSat [g | g@(WXNext _ _) <- zClos encData]
            mkImplies ySuppClosed allSat

      mkForallNodes [1..x] allXnextSat
    -}

    mkWxnext :: MonadZ3 z3 => [Formula MP.ExprProp] -> Word64 -> AST -> AST -> z3 AST
    mkWxnext allWxnext x _ checkPopx = do
      let struct = zStruct encData
      xLit <- mkUnsignedInt64 x $ zNodeSort encData
      structx <- mkApp1 struct xLit
      ctxx <- mkApp1 (zCtx encData) xLit
      structCtxx <- mkApp1 struct ctxx
      let wxnextSat g@(WXNext dir arg) = do
            gammagctxx <- mkApp (zGamma encData) [zFConstMap encData M.! g, ctxx]
            precYT <- case dir of
              Down -> mkApp (zYield encData) [structCtxx, structx]
              Up   -> mkApp (zTake encData) [structCtxx, structx]
            precEq <- mkApp (zEqual encData) [structCtxx, structx]
            orPrec <- mkOr [precYT, precEq]
            gammagctxxAndOrPrec <- mkAnd [gammagctxx, orPrec]
            xnfArgx <- groundxnf encData arg xLit
            mkImplies gammagctxxAndOrPrec xnfArgx
      mkImplies checkPopx =<< mkAndWith wxnextSat allWxnext

    mkHnextu :: MonadZ3 z3 => [Formula MP.ExprProp] -> Word64 -> AST -> AST -> AST -> z3 AST
    mkHnextu allHnu x checkPushx _ checkPopx = do
        let nodeSort = zNodeSort encData
        xLit <- mkUnsignedInt64 x nodeSort
        stackx <- mkApp1 (zStack encData) xLit
        xp1 <- mkUnsignedInt64 (x + 1) nodeSort
        checkPushxp1 <- mkCheckPrec encData (zYield encData) xp1
        let hnextuSat g@(HNext Up arg) = do
              gammagstackx <- mkApp (zGamma encData) [zFConstMap encData M.! g, stackx]
              xnfArgx <- groundxnf encData arg xLit
              mkImplies gammagstackx =<< mkAnd [xnfArgx, checkPushxp1]
        allHnextuSat <- mkAndWith hnextuSat allHnu
        popxImplies <- mkImplies checkPopx allHnextuSat

        hucond <- mkHUCond x checkPushx checkPopx allHnu
        mkAnd [popxImplies, hucond]

    mkWhnextu :: MonadZ3 z3 => [Formula MP.ExprProp] -> Word64 -> AST -> AST -> AST -> z3 AST
    mkWhnextu allWhnu x _ _ checkPopx = do
        let nodeSort = zNodeSort encData
            yield = zYield encData
            pred = zPred encData
        xLit <- mkUnsignedInt64 x nodeSort
        predx <- mkApp1 pred xLit
        xm1 <- mkUnsignedInt64 (x - 1) nodeSort
        predxEqxm1 <- mkEq predx xm1

        stackx <- mkApp1 (zStack encData) xLit
        checkPushStackx <- mkCheckPrec encData yield stackx
        stackxm1 <- mkApp1 pred stackx
        checkPopStackxm1 <- mkCheckPrec encData (zTake encData) stackxm1

        xp1 <- mkUnsignedInt64 (x + 1) nodeSort
        checkPushxp1 <- mkCheckPrec encData yield xp1

        implLhs <- mkAnd [checkPopx, checkPushxp1, checkPopStackxm1, checkPushStackx]

        let whnextuSat g@(WHNext Up arg) = do
              gammagStackx <- mkApp (zGamma encData) [zFConstMap encData M.! g, stackx]
              xnfArgx <- groundxnf encData arg xLit
              mkImplies gammagStackx xnfArgx
        allWhnextuSat <- mkImplies implLhs =<< mkAndWith whnextuSat allWhnu
        mkAnd [predxEqxm1, allWhnextuSat]

    mkHnextd :: MonadZ3 z3 => [Formula MP.ExprProp] -> Word64 -> AST -> AST -> AST -> z3 AST
    mkHnextd allHnd x _ _ checkPopx = do
        let nodeSort = zNodeSort encData
            ctx = zCtx encData
            take = zTake encData
        xLit <- mkUnsignedInt64 x nodeSort
        ctxx <- mkApp1 ctx xLit
        xp1 <- mkUnsignedInt64 (x + 1) nodeSort
        checkPopxp1 <- mkCheckPrec encData take xp1
        lhs <- mkAnd [checkPopx, checkPopxp1]
        xm1 <- mkUnsignedInt64 (x - 1) nodeSort
        ctxxm1 <- mkApp1 ctx xm1
        checkPopxm1 <- mkCheckPrec encData take xm1
        let hnextdSat g@(HNext Down arg) = do
              gammagCtxx <- mkApp (zGamma encData) [zFConstMap encData M.! g, ctxx]
              xnfArgCtxxm1 <- groundxnf encData arg ctxxm1
              mkImplies gammagCtxx =<< mkAnd [xnfArgCtxxm1, checkPopxm1]
        popImpl <- mkImplies lhs =<< mkAndWith hnextdSat allHnd
        hdcond <- mkHDCond x checkPopx allHnd
        mkAnd [popImpl, hdcond]

    mkWhnextd :: MonadZ3 z3 => [Formula MP.ExprProp] -> Word64 -> AST -> AST -> AST -> z3 AST
    mkWhnextd allWhnd x _ _ checkPopx = do
        let nodeSort = zNodeSort encData
            ctx = zCtx encData
            take = zTake encData
        xLit <- mkUnsignedInt64 x nodeSort
        ctxx <- mkApp1 ctx xLit
        xm1 <- mkUnsignedInt64 (x - 1) nodeSort
        checkPopxm1 <- mkCheckPrec encData take xm1
        xp1 <- mkUnsignedInt64 (x + 1) nodeSort
        checkPopxp1 <- mkCheckPrec encData take xp1
        lhs <- mkAnd [checkPopx, checkPopxm1, checkPopxp1]
        ctxxm1 <- mkApp1 ctx xm1
        let whnextdSat g@(WHNext Down arg) = do
              gammagCtxx <- mkApp (zGamma encData) [zFConstMap encData M.! g, ctxx]
              xnfArgCtxxm1 <- groundxnf encData arg ctxxm1
              mkImplies gammagCtxx xnfArgCtxxm1
        mkImplies lhs =<< mkAndWith whnextdSat allWhnd

    mkHuaux :: MonadZ3 z3 => [Formula MP.ExprProp] -> Word64 -> AST -> AST -> z3 AST
    mkHuaux _ x checkPushx checkPopx = do
      let nodeSort = zNodeSort encData
      xm1 <- mkUnsignedInt64 (x - 1) nodeSort
      checkPopxm1 <- mkCheckPrec encData (zTake encData) xm1
      whenNotPop <- mkAnd [checkPushx, checkPopxm1]
      hucond <- mkOr [checkPopx, whenNotPop]

      xLit <- mkUnsignedInt64 x nodeSort
      huaux <- mkApp (zGamma encData) [zFConstMap encData M.! HUntil Up T T, xLit]
      huauxImplies <- mkImplies huaux hucond

      impliesHuaux <- mkImplies whenNotPop huaux
      mkAnd [huauxImplies, impliesHuaux]

    mkHdaux :: MonadZ3 z3 => [Formula MP.ExprProp] -> Word64 -> AST -> AST -> AST -> z3 AST
    mkHdaux _ x _ _ checkPopx = do
      let nodeSort = zNodeSort encData
      xLit <- mkUnsignedInt64 x nodeSort
      ctxx <- mkApp1 (zCtx encData) xLit
      xp1 <- mkUnsignedInt64 (x + 1) nodeSort
      checkPopxp1 <- mkCheckPrec encData (zTake encData) xp1
      popxAndPopxp1 <- mkAnd [checkPopx, checkPopxp1]
      hdaux <- mkApp (zGamma encData) [zFConstMap encData M.! HUntil Down T T, ctxx]
      impliesHdaux <- mkImplies popxAndPopxp1 hdaux
      hdcond <- mkHDCond x checkPopx [HUntil Down T T]
      mkAnd [impliesHdaux, hdcond]

    mkHUCond :: MonadZ3 z3 => Word64 -> AST -> AST -> [Formula MP.ExprProp] -> z3 AST
    mkHUCond x checkPushx checkPopx allOps = do
      let nodeSort = zNodeSort encData
      xm1 <- mkUnsignedInt64 (x - 1) nodeSort
      checkPopxm1 <- mkCheckPrec encData (zTake encData) xm1
      whenNotPop <- mkAnd [checkPushx, checkPopxm1]
      hucond <- mkOr [checkPopx, whenNotPop]

      xLit <- mkUnsignedInt64 x nodeSort
      anyOpsx <- mkOrWith (\g -> mkApp (zGamma encData) [zFConstMap encData M.! g, xLit]) allOps
      mkImplies anyOpsx hucond

    mkHDCond :: MonadZ3 z3 => Word64 -> AST -> [Formula MP.ExprProp] -> z3 AST
    mkHDCond x checkPopx allOps = do
      let nodeSort = zNodeSort encData
          fConstMap = zFConstMap encData
          gamma = zGamma encData
      xLit <- mkUnsignedInt64 x nodeSort
      notPopx <- mkNot checkPopx
      anyOpsx <- mkOrWith (\g -> mkApp gamma [fConstMap M.! g, xLit]) allOps
      notPopxAndAnyOpsx <- mkAnd [notPopx, anyOpsx]
      xp1 <- mkUnsignedInt64 (x + 1) nodeSort
      checkPushxp1 <- mkCheckPrec encData (zYield encData) xp1
      notPopImpl <- mkImplies notPopxAndAnyOpsx checkPushxp1

      ctxx <- mkApp1 (zCtx encData) xLit
      anyOpsCtxx <- mkOrWith (\g -> mkApp gamma [fConstMap M.! g, ctxx]) allOps
      popxAndAnyOpsCtxx <- mkAnd [checkPopx, anyOpsCtxx]
      notShiftxp1 <- mkNot =<< mkCheckPrec encData (zEqual encData) xp1
      popImpl <- mkImplies popxAndAnyOpsCtxx notShiftxp1

      mkAnd [notPopImpl, popImpl]

    mkNextBackRules :: MonadZ3 z3 => Word64 -> z3 AST
    mkNextBackRules x = do
      let clos = zClos encData
          nodeSort = zNodeSort encData
          fConstMap = zFConstMap encData
          gamma = zGamma encData
      xLit <- mkUnsignedInt64 x nodeSort
      xp1 <- mkUnsignedInt64 (x + 1) nodeSort
      -- Γ(#, x)
      gammaEndxp1 <- mkApp gamma [fConstMap M.! Atomic End, xp1]
      -- PNext, Next and WNext
      let propagateNext (next, arg, weak) = do
            lhs <- mkApp gamma [fConstMap M.! next, xLit]
            ground <- groundxnf encData arg xp1
            rhs <- if weak -- Just for finite-word semantics
                   then mkOr [gammaEndxp1, ground]
                   else mkNot gammaEndxp1 >>= (\noend -> mkAnd [noend, ground])
            mkImplies lhs rhs
      -- big and
      nextRule <- mkAndWith propagateNext
        ([(g, alpha, False) | g@(PNext _ alpha) <- clos]
         ++ [(g, alpha, False) | g@(Next alpha) <- clos]
         ++ [(g, alpha, True) | g@(WNext alpha) <- clos])
      -- Back and WBack
      let propagateBack (back, arg) = do
            lhs <- mkApp gamma [fConstMap M.! back, xp1]
            rhs <- groundxnf encData arg xLit
            mkImplies lhs rhs
      -- big and
      backRule <- mkAndWith propagateBack
        ([(g, alpha) | g@(Back alpha) <- clos]
         ++ [(g, alpha) | g@(WBack alpha) <- clos])
      mkAnd [nextRule, backRule]

    -- PUSH(x)
    mkPush :: MonadZ3 z3 => Word64 -> z3 AST
    mkPush x = do
      let nodeSort = zNodeSort encData
      -- Propagate Next and Back operators
      nextBackRules <- mkNextBackRules x
      -- Bookkeeping functions
      xLit <- mkUnsignedInt64 x nodeSort
      xp1 <- mkUnsignedInt64 (x + 1) nodeSort
      -- smb(x + 1) = struct(x)
      smbxp1 <- mkApp1 (zSmb encData) xp1
      structx <- mkApp1 (zStruct encData) xLit
      smbRule <- mkEq smbxp1 structx
      -- stack(x + 1) = x
      stackxp1 <- mkApp1 (zStack encData) xp1
      stackRule <- mkEq stackxp1 xLit
      -- stack(x) = ⊥ → ctx(x + 1) = ⊥
      nodeBot <- mkUnsignedInt64 0 nodeSort
      stackx <- mkApp1 (zStack encData) xLit
      ctxxp1 <- mkApp1 (zCtx encData) xp1
      stackxEqBot <- mkEq stackx nodeBot
      ctxxp1EqBot <- mkEq ctxxp1 nodeBot
      botCtxRule <- mkImplies stackxEqBot ctxxp1EqBot
      -- (stack(x) != ⊥ ∧ (push(x − 1) ∨ shift(x − 1))) → ctx(x + 1) = x − 1
      stackxNeqBot <- mkNot =<< mkEq stackx nodeBot
      xm1 <- mkUnsignedInt64 (x - 1) nodeSort
      pushxm1 <- mkCheckPrec encData (zYield encData) xm1
      shiftxm1 <- mkCheckPrec encData (zEqual encData) xm1
      pushOrShiftxm1 <- mkOr [pushxm1, shiftxm1]
      stackxNeqBotAndpushOrShiftxm1 <- mkAnd [stackxNeqBot, pushOrShiftxm1]
      ctxxp1Eqxm1 <- mkEq ctxxp1 xm1
      pushShiftCtxRule <- mkImplies stackxNeqBotAndpushOrShiftxm1 ctxxp1Eqxm1
      -- (stack(x) != ⊥ ∧ pop(x − 1)) → ctx(x + 1) = ctx(x - 1)
      popxm1 <- mkCheckPrec encData (zTake encData) xm1
      stackxNeqBotAndPopxm1 <- mkAnd [stackxNeqBot, popxm1]
      ctxxm1 <- mkApp1 (zCtx encData) xm1
      ctxxp1Eqctxx <- mkEq ctxxp1 ctxxm1
      popCtxRule <- mkImplies stackxNeqBotAndPopxm1 ctxxp1Eqctxx
      -- Final and
      mkAnd [ nextBackRules
            , smbRule, stackRule
            , botCtxRule, pushShiftCtxRule, popCtxRule
            ]

    -- SHIFT(x)
    mkShift :: MonadZ3 z3 => Word64 -> z3 AST
    mkShift x = do
      let nodeSort = zNodeSort encData
          stack = zStack encData
          ctx = zCtx encData
      -- Propagate Next and Back operators
      nextBackRules <- mkNextBackRules x
      -- Bookkeeping functions
      xLit <- mkUnsignedInt64 x nodeSort
      xp1 <- mkUnsignedInt64 (x + 1) nodeSort
      -- smb(x + 1) = struct(x)
      smbxp1 <- mkApp1 (zSmb encData) xp1
      structx <- mkApp1 (zStruct encData) xLit
      smbRule <- mkEq smbxp1 structx
      -- stack(x + 1) = x
      stackxp1 <- mkApp1 stack xp1
      stackx <- mkApp1 stack xLit
      stackRule <- mkEq stackxp1 stackx
      -- ctx(x + 1) = ctx(x)
      ctxxp1 <- mkApp1 ctx xp1
      ctxx <- mkApp1 ctx xLit
      ctxRule <- mkEq ctxxp1 ctxx
      -- Final and
      mkAnd [nextBackRules, smbRule, stackRule, ctxRule]

    -- POP(xExpr)
    mkPop :: MonadZ3 z3 => Word64 -> z3 AST
    mkPop x = do
      let nodeSort = zNodeSort encData
          gamma = zGamma encData
          smb = zSmb encData
          stack = zStack encData
          ctx = zCtx encData
      xLit <- mkUnsignedInt64 x nodeSort
      xp1 <- mkUnsignedInt64 (x + 1) nodeSort
      stackx <- mkApp1 stack xLit
      -- ∀p((Γ(p, x) ∨ Γ((HNext Up p)_G, stack(x))) ↔ Γ(p, x + 1))
      let mkForallIff f = do
            let p = zFConstMap encData M.! f
            gammapx <- mkApp gamma [p, xLit]
            gammapxp1 <- mkApp gamma [p, xp1]
            mkIff gammapx gammapxp1
      gammaRule <- mkAndWith mkForallIff $ zClos encData
      -- smb(x + 1) = smb(stack(x))
      smbxp1 <- mkApp1 smb xp1
      smbstackx <- mkApp1 smb stackx
      smbRule <- mkEq smbxp1 smbstackx
      -- stack(x + 1) = stack(stack(x))
      stackxp1 <- mkApp1 stack xp1
      stackstackx <- mkApp1 stack stackx
      stackRule <- mkEq stackxp1 stackstackx
      -- ctx(x + 1) = ctx(stack(x))
      ctxxp1 <- mkApp1 ctx xp1
      ctxstackx <- mkApp1 ctx stackx
      ctxRule <- mkEq ctxxp1 ctxstackx
      -- Final and
      mkAnd [gammaRule, smbRule, stackRule, ctxRule]

-- xnf(theta)_G(x)
groundxnf :: MonadZ3 z3 => EncData -> Formula MP.ExprProp -> AST -> z3 AST
groundxnf encData theta x = ground (xnf theta) where
  ground f = case f of
    T                -> mkTrue
    Atomic _         -> applyGamma f
    Not T            -> mkFalse
    Not g@(Atomic _) -> mkNot =<< applyGamma g
    Not _            -> error "Supplied formula is not in Positive Normal Form."
    Or g h           -> boolPred (\a b -> mkOr [a, b]) g h
    And g h          -> boolPred (\a b -> mkAnd [a, b]) g h
    Xor g h          -> boolPred mkXor g h
    Implies g h      -> boolPred mkImplies g h
    Iff g h          -> boolPred mkEq g h
    PNext _ _        -> applyGamma f
    PBack _ _        -> error "Past operators not supported yet."
    WPNext _ _       -> applyGamma f
    XNext _ _        -> applyGamma f
    XBack _ _        -> error "Past operators not supported yet."
    WXNext _ _       -> applyGamma f
    HNext _ _        -> applyGamma f
    HBack _ _        -> error "Hierarchical operators not supported yet."
    WHNext _ _       -> applyGamma f
    Until _ _ _      -> error "Supplied formula is not in Next Normal Form."
    Release _ _ _    -> error "Supplied formula is not in Next Normal Form."
    Since _ _ _      -> error "Past operators not supported yet."
    HUntil _ _ _     -> applyGamma f
    HRelease _ _ _   -> applyGamma f
    HSince _ _ _     -> error "Supplied formula is not in Next Normal Form."
    Next _           -> applyGamma f
    WNext _          -> applyGamma f
    Back _           -> applyGamma f
    WBack _          -> applyGamma f
    Eventually _     -> error "Supplied formula is not in Next Normal Form."
    Always _         -> error "Supplied formula is not in Next Normal Form."
    Once _           -> error "Supplied formula is not in Next Normal Form."
    Historically _   -> error "Supplied formula is not in Next Normal Form."
    AuxBack _ _      -> error "AuxBack not supported in SMT encoding."
    where boolPred op lhs rhs = do
            glhs <- ground lhs
            grhs <- ground rhs
            op glhs grhs

          applyGamma g = mkApp (zGamma encData) [zFConstMap encData M.! g, x]

mkPhiAssumptions :: MonadZ3 z3 => Bool -> EncData -> Word64 -> z3 [AST]
mkPhiAssumptions False encData k = do
  let nodeSort = zNodeSort encData
  kLit <- mkUnsignedInt64 k nodeSort
  -- Γ(#, k)
  gammaEndk <- mkApp (zGamma encData) [zFConstMap encData M.! Atomic End, kLit]
  -- stack(x) = ⊥
  stackk <- mkApp1 (zStack encData) kLit
  stackkEqBot <- mkEq stackk =<< mkUnsignedInt64 0 nodeSort
  return [gammaEndk, stackkEqBot]
mkPhiAssumptions True encData k = do
  let clos = zClos encData
  noNextk <- mkNot =<< mkAnyGammagx k
             (filter (\g -> case g of
                         Next _    -> True
                         PNext _ _ -> True
                         XNext _ _ -> True
                         HNext _ _ -> True
                         HUntil _ T T -> True
                         _ -> False
                     ) clos)
  let forallRules x = do
        anyHier <- mkAnyGammagx x $ filter (\g -> case g of
                                               XNext _ _ -> True
                                               HNext _ _ -> True
                                               WHNext Down _ -> True
                                               HUntil Down _ _ -> True
                                               HRelease Down _ _ -> True
                                               _ -> False
                                           ) clos
        mkImplies anyHier =<< mkNot =<< mkPending encData k x
  forAll <- mkForallNodes [1..k] forallRules
  return [noNextk, forAll]
  where
    mkAnyGammagx :: MonadZ3 z3 => Word64 -> [Formula MP.ExprProp] -> z3 AST
    mkAnyGammagx x gs = do
      xLit <- mkUnsignedInt64 x $ zNodeSort encData
      mkOrWith (\g -> mkApp (zGamma encData) [zFConstMap encData M.! g, xLit]) gs

-- PENDING(k, x)
mkPending :: MonadZ3 z3 => EncData -> Word64 -> Word64 -> z3 AST
mkPending encData k x = do
  let nodeSort = zNodeSort encData
      stack = zStack encData
  xLit <- mkUnsignedInt64 x nodeSort
  checkPushx <- mkCheckPrec encData (zYield encData) xLit
  forallPush <- mkForallNodes [(x+1)..(k-1)]
                (\u -> do
                    uLit <- mkUnsignedInt64 u nodeSort
                    checkPopu <- mkCheckPrec encData (zTake encData) uLit
                    stackuEqx <- mkEq xLit =<< mkApp1 stack uLit
                    mkNot =<< mkAnd [checkPopu, stackuEqx]
                )
  pushAndForall <- mkAnd [checkPushx, forallPush]

  checkShiftx <- mkCheckPrec encData (zEqual encData) xLit
  stackx <- mkApp1 stack xLit
  forallShift <- mkForallNodes [(x+1)..(k-1)]
                 (\u -> do
                     uLit <- mkUnsignedInt64 u nodeSort
                     checkPopu <- mkCheckPrec encData (zTake encData) uLit
                     stackxEqStacku <- mkEq stackx =<< mkApp1 stack uLit
                     mkNot =<< mkAnd [checkPopu, stackxEqStacku]
                 )
  shiftAndForall <- mkAnd [checkShiftx, forallShift]
  mkOr [pushAndForall, shiftAndForall]

assertPrune :: MonadZ3 z3 => Bool -> EncData -> Maybe ProgData -> Word64 -> z3 ()
assertPrune fastPrune encData maybeProgData x
  | fastPrune = do
      let nodeSort = zNodeSort encData
          smb = zSmb encData
          stack = zStack encData
          ctx = zCtx encData
      xLit <- mkUnsignedInt64 x nodeSort
      smbx <- mkApp1 smb xLit
      stackx <- mkApp1 stack xLit
      ctxx <- mkApp1 ctx xLit
      prune1 <- mkExistsNodes [1..(x-1)]
                (\y -> do
                    yLit <- mkUnsignedInt64 y nodeSort
                    sameFsxy <- mkSameFs xLit yLit
                    smbxy <- mkEq smbx =<< mkApp1 smb yLit
                    stackxy <- mkEq stackx =<< mkApp1 stack yLit
                    ctxxy <- mkEq ctxx =<< mkApp1 ctx yLit
                    sameProgStatus <- mkSameProgStatus xLit yLit
                    mkAnd [sameFsxy, smbxy, stackxy, ctxxy, sameProgStatus]
                )
      assert =<< mkNot prune1
      assertPrune2
  | otherwise = assertPrune2
  where
    assertPrune2 = do
      let nodeSort = zNodeSort encData
          smb = zSmb encData
          stack = zStack encData
      xLit <- mkUnsignedInt64 x nodeSort
      smbx <- mkApp1 smb xLit
      stackx <- mkApp1 stack xLit
      -- ctxx <- mkApp1 (zCtx encData) xLit
      assert =<< mkNot =<< mkExistsNodes [1..(x-1)]
        (\y -> do
            yLit <- mkUnsignedInt64 y nodeSort
            pending <- mkPending encData x y
            sameFsxy <- mkSameFs xLit yLit
            smbxy <- mkEq smbx =<< mkApp1 smb yLit
            sameFsStack <- mkSameFs stackx =<< mkApp1 stack yLit
            -- sameFsCtx <- mkSameFs ctxx =<< mkApp1 ctx yLit
            sameProgStatus <- mkSameProgStatus xLit yLit
            mkAnd [pending, sameFsxy, smbxy, sameFsStack, {-sameFsCtx,-} sameProgStatus]
        )

    mkSameFs u v = mkAndWith
      (\c -> do
          let gamma = zGamma encData
          gammacu <- mkApp gamma [c, u]
          gammacv <- mkApp gamma [c, v]
          mkEq gammacu gammacv
      ) $ M.elems $ zFConstMap encData

    mkSameProgStatus xLit yLit = case maybeProgData of
      Nothing -> mkTrue
      Just progData -> do
        pcx <- mkApp1 (zPc progData) xLit
        samePc <- mkEq pcx =<< mkApp1 (zPc progData) yLit
        sameVars <- mkAndWith (\varEnc -> mkVarCopy varEnc varEnc xLit yLit)
                    $ V.toList $ zVarEncVec progData
        mkAnd [samePc, sameVars]


data ProgData = ProgData { zProg       :: MP.Program
                         , zLocSort    :: Sort
                         , zPc         :: FuncDecl
                         , zVarEncVec  :: Vector VarEncoder
                         , zLowerState :: MP.LowerState
                         , zFin        :: [Word]
                         }

data VarEncoder = VarEncoder { zVarFun     :: FuncDecl
                             , zScalarSort :: Sort
                             , zVarData    :: VarEncData
                             }
data VarEncData = Scalar
                | ArrayTheory { zAIdxSort :: Sort }
                | UFArray { zVarType   :: MP.Type
                          , zUFIdxSort :: Sort
                          }

mkVarEncoder :: MonadZ3 z3 => Bool -> EncData -> MP.Variable -> z3 VarEncoder
mkVarEncoder useArrays encData var = do
  let ty = MP.varType var
      vname = T.unpack $ MP.varName var
      nodeSort = zNodeSort encData
      logBase2Sup x = finiteBitSize x - countLeadingZeros x
  scalarSort <- mkBvSort $ MP.typeWidth ty
  if | MP.isScalar ty -> do
         varFunc <- mkFreshFuncDecl vname [nodeSort] scalarSort
         return $ VarEncoder { zVarFun = varFunc, zScalarSort = scalarSort, zVarData = Scalar }
     | useArrays -> do
         idxSort <- mkBvSort $ logBase2Sup (max 1 $ MP.arraySize ty - 1)
         arrSort <- mkArraySort idxSort scalarSort
         varFunc <- mkFreshFuncDecl vname [nodeSort] arrSort
         return $ VarEncoder { zVarFun = varFunc
                             , zScalarSort = scalarSort
                             , zVarData = ArrayTheory { zAIdxSort = idxSort }
                             }
     | otherwise -> do
         idxSort <- mkBvSort $ logBase2Sup (max 1 $ MP.arraySize ty - 1)
         varFunc <- mkFreshFuncDecl vname [nodeSort, idxSort] scalarSort
         return $ VarEncoder { zVarFun = varFunc
                             , zScalarSort = scalarSort
                             , zVarData = UFArray { zVarType = ty
                                                  , zUFIdxSort = idxSort
                                                  }
                             }

assignUFArrayIf :: MonadZ3 z3 => VarEncoder -> (AST -> z3 AST) -> (AST -> AST -> z3 AST) -> AST -> z3 AST
assignUFArrayIf varEnc mkRhs mkIf xLit =
  let varData = zVarData varEnc
      elemEq i = do
        iLit <- mkUnsignedInt i $ zUFIdxSort varData
        vx <- mkApp (zVarFun varEnc) [xLit, iLit]
        mkIf iLit =<< mkEq vx =<< mkRhs iLit
  in mkAndWith elemEq [0..((fromIntegral (MP.arraySize $ zVarType varData) :: Word) - 1)]

assignUFArray :: MonadZ3 z3 => VarEncoder -> (AST -> z3 AST) -> AST -> z3 AST
assignUFArray varEnc mkRhs xLit = assignUFArrayIf varEnc mkRhs (\_ ast -> return ast) xLit

mkInit0Var :: MonadZ3 z3 => VarEncoder -> AST -> z3 AST
mkInit0Var varEnc xLit = do
  val0 <- mkUnsignedInt 0 $ zScalarSort varEnc
  case zVarData varEnc of
    Scalar -> mkEq val0 =<< mkApp1 (zVarFun varEnc) xLit
    ArrayTheory idxSort -> do
      arr0 <- mkConstArray idxSort val0
      mkEq arr0 =<< mkApp1 (zVarFun varEnc) xLit
    UFArray {} -> assignUFArray varEnc (const $ return val0) xLit

mkInit0 :: MonadZ3 z3 => Vector VarEncoder -> [MP.Variable] -> AST -> z3 AST
mkInit0 varEncVec vars xLit =
  mkAndWith (\v -> mkInit0Var (varEncVec V.! MP.varId v) xLit) vars

mkVarCopy :: MonadZ3 z3 => VarEncoder -> VarEncoder -> AST -> AST -> z3 AST
mkVarCopy xVarEnc yVarEnc xLit yLit =
  let xVarFun = zVarFun xVarEnc
      yVarFun = zVarFun yVarEnc
      simpleAssign = do
        vx <- mkApp1 xVarFun xLit
        vy <- mkApp1 yVarFun yLit
        mkEq vx vy
  in case zVarData xVarEnc of
    Scalar -> simpleAssign
    ArrayTheory {} -> simpleAssign
    UFArray {} -> assignUFArray xVarEnc (\iLit -> mkApp yVarFun [yLit, iLit]) xLit

initProgEncoding :: MonadZ3 z3 => Bool -> EncData -> MP.Program -> z3 ProgData
initProgEncoding useArrays encData prog = do
  let (lowerState, ini, fin) = MP.sksToExtendedOpa False (MP.pSks prog)
      nodeSort = zNodeSort encData
  locSortSymbol <- mkStringSymbol "LocSort"
  locSort <- mkFiniteDomainSort locSortSymbol $ fromIntegral $ MP.lsSid lowerState
  -- Uninterpreted functions
  pc <- mkFreshFuncDecl "pc" [nodeSort] locSort
  varEncVec <- mkVarFunctions
  let progData = ProgData { zProg = prog
                          , zLocSort = locSort
                          , zPc = pc
                          , zVarEncVec = varEncVec
                          , zLowerState = lowerState
                          , zFin = fin
                          }
  -- Initial locations
  node1 <- mkUnsignedInt64 1 nodeSort
  assert =<< mkOrWith (\l -> do
                          lLit <- mkUnsignedInt l locSort
                          pc1 <- mkApp1 pc node1
                          mkEq pc1 lLit
                      ) ini
  -- Initialize variables
  nodeBot <- mkUnsignedInt64 0 nodeSort
  assert =<< mkInit0 varEncVec allVariables nodeBot
  assert =<< mkInit0 varEncVec allVariables node1
  return progData
  where
    allScalars = S.toList (MP.pGlobalScalars prog) ++ S.toList (MP.pLocalScalars prog)
    allArrays = S.toList (MP.pGlobalArrays prog) ++ S.toList (MP.pLocalArrays prog)
    allVariables = allScalars ++ allArrays
    mkVarFunctions =
      let varMap = M.fromListWith (\v _ -> error $ "Repeated var ID " ++ show (MP.varId v))
            $ map (\v -> (MP.varId v, v)) allVariables
      in V.generateM (M.size varMap) (mkVarEncoder useArrays encData . (varMap M.!))

assertProgEncoding :: MonadZ3 z3 => EncData -> ProgData -> Word64 -> Word64 -> z3 ()
assertProgEncoding encData progData from to = do
  -- start ∀x (...)
  -- x < k
  let lowerState = zLowerState progData
      mkProgTransitions x = do
        xLit <- mkUnsignedInt64 x $ zNodeSort encData
        -- push(x) → PUSH(x)
        checkPushx <- mkCheckPrec encData (zYield encData) xLit
        pushProgx <- mkInput (MP.lsDPush lowerState) x
        pushxImpliesPushProgx <- mkImplies checkPushx pushProgx
        -- shift(x) → SHIFT(x)
        checkShiftx <- mkCheckPrec encData (zEqual encData) xLit
        shiftProgx <- mkInput (MP.lsDShift lowerState) x
        shiftxImpliesShiftProgx <- mkImplies checkShiftx shiftProgx
        -- pop(x) → POP(x)
        checkPopx <- mkCheckPrec encData (zTake encData) xLit
        popProgx <- mkPop (MP.lsDPop lowerState) x
        popxImpliesPopProgx <- mkImplies checkPopx popProgx
        mkAnd [pushxImpliesPushProgx, shiftxImpliesShiftProgx, popxImpliesPopProgx]
  assert =<< mkAndWith mkProgTransitions [((max 2 from) - 1)..(to - 1)]
  -- end ∀x (...)
  where
    apConstMap = M.fromList
      $ foldr (\(p, c) rest -> case p of
                  Atomic tp@(Prop (MP.TextProp t))
                    | tp `notElem` (fst MP.miniProcAlphabet) -> (t, c):rest
                  _ -> rest
              ) []
      $ M.toList $ zFConstMap encData
    exprPropMap = foldr (\(exprF, exprS) rest -> case exprF of
                            Atomic (Prop (MP.ExprProp s e)) -> (s, e, exprS):rest
                            _ -> rest
                        ) []
                  $ M.toList $ zFConstMap encData

    mkInput :: MonadZ3 z3 => Map Word (MP.InputLabel, MP.DeltaTarget) -> Word64 -> z3 AST
    mkInput lsDelta x =
      mkOrWith mkTransition $ M.toList lsDelta where
      mkTransition (l1, (il, MP.States dt)) = do
        let nodeSort = zNodeSort encData
            gamma = zGamma encData
            varEncVec = zVarEncVec progData
            locSort = zLocSort progData
            pc = zPc progData
        xLit <- mkUnsignedInt64 x nodeSort
        xp1 <- mkUnsignedInt64 (x + 1) nodeSort
        -- pc(x) = l1
        l1Lit <- mkUnsignedInt l1 locSort
        pcX <- mkApp1 pc xLit
        pcXEqL1 <- mkEq l1Lit pcX
        -- ∧_(p∈b) Γ(p, x)
        structX <- mkApp1 (zStruct encData) xLit
        structXEqil <- mkEq (zFConstMap encData M.! (Atomic . Prop . MP.TextProp . MP.ilStruct $ il))
                       structX
        let inputNames = (MP.ilFunction il) : (MP.ilModules il)
        inputProps <- mkAndWith (\(l, c) -> let pn | l `elem` inputNames = return
                                                   | otherwise = mkNot
                                            in pn =<< mkApp gamma [c, xLit]
                                ) $ M.toList apConstMap
        -- assert ExprProps
        let assertExprProp (scope, expr, exprS) = do
              gammaExprx <- mkApp gamma [exprS, xLit]
              if isNothing scope || fromJust scope == MP.ilFunction il
                then mkIff gammaExprx =<< evalBoolExpr varEncVec expr xLit
                else mkNot gammaExprx
        exprProps <- mkAndWith assertExprProp exprPropMap
        -- ACTION(x, _, a)
        action <- mkAction varEncVec x Nothing $ MP.ilAction il
        -- g|x ∧ pc(x + 1) = l2
        targets <- mkOrWith (\(g, l2) -> do
                                -- pc(x + 1) = l2
                                l2Lit <- mkUnsignedInt l2 locSort
                                pcXp1 <- mkApp1 pc xp1
                                nextPc <- mkEq pcXp1 l2Lit
                                case g of
                                  MP.NoGuard -> return nextPc
                                  MP.Guard e -> do
                                    guard <- evalBoolExpr varEncVec e xp1
                                    mkAnd [guard, nextPc]
                            ) dt
        mkAnd [pcXEqL1, structXEqil, inputProps, action, exprProps, targets]

    mkPop :: MonadZ3 z3 => Map (Word, Word) (MP.Action, MP.DeltaTarget) -> Word64 -> z3 AST
    mkPop lsDelta x =
      mkOrWith mkTransition $ M.toList lsDelta where
      mkTransition ((l1, ls), (act, MP.States dt)) = do
        let nodeSort = zNodeSort encData
            varEncVec = zVarEncVec progData
            locSort = zLocSort progData
            pc = zPc progData
        xLit <- mkUnsignedInt64 x nodeSort
        xp1 <- mkUnsignedInt64 (x + 1) nodeSort
        -- pc(x) = l1
        l1Lit <- mkUnsignedInt l1 locSort
        pcX <- mkApp1 pc xLit
        pcXEqL1 <- mkEq pcX l1Lit
        -- pc(stack(x)) = ls
        stackX <- mkApp1 (zStack encData) xLit
        lsLit <- mkUnsignedInt ls locSort
        pcStackX <- mkApp1 pc stackX
        pcStackXEqLs <- mkEq pcStackX lsLit
        -- ACTION(x, stack(x), a)
        action <- mkAction varEncVec x (Just stackX) act
        -- g|x ∧ pc(x + 1) = l2
        targets <- mkOrWith (\(g, l2) -> do
                                -- pc(x + 1) = l2
                                l2Lit <- mkUnsignedInt l2 locSort
                                pcXp1 <- mkApp1 pc xp1
                                nextPc <- mkEq pcXp1 l2Lit
                                case g of
                                  MP.NoGuard -> return nextPc
                                  MP.Guard e -> do
                                    guard <- evalBoolExpr varEncVec e xp1
                                    mkAnd [guard, nextPc]
                            ) dt
        mkAnd [pcXEqL1, pcStackXEqLs, action, targets]

    mkAction :: MonadZ3 z3 => Vector VarEncoder -> Word64 -> Maybe AST -> MP.Action -> z3 AST
    mkAction varEncVec x poppedNode action = do
      let nodeSort = zNodeSort encData
      xLit <- mkUnsignedInt64 x nodeSort
      xp1 <- mkUnsignedInt64 (x + 1) nodeSort
      let propvals :: MonadZ3 z3 => [MP.Variable] -> z3 AST
          propvals except =
            let excSet = S.fromList $ map MP.varId except
            in mkAnd =<< V.ifoldM (\rest i varEnc -> if i `S.member` excSet
                                    then return rest
                                    else (:rest) <$> mkVarCopy varEnc varEnc xLit xp1
                                  ) [] varEncVec

          mkArrayStore arrVar idxExpr maybeRhs = do
            let varEnc = varEncVec V.! MP.varId arrVar
                varFun = zVarFun varEnc
            evalIdx <- evalExpr varEncVec idxExpr xLit
            castIdx <- castArrayIndex varEnc evalIdx
            case zVarData varEnc of
              ArrayTheory {} -> do
                evalRhs <- case maybeRhs of
                  Just rhs -> evalExpr varEncVec rhs xLit
                  Nothing -> mkFreshConst (T.unpack $ MP.varName arrVar) $ zScalarSort varEnc
                lhsx <- mkApp1 varFun xLit
                lhsXp1 <- mkApp1 varFun xp1
                mkEq lhsXp1 =<< mkStore lhsx castIdx evalRhs
              UFArray {} -> do
                propRest <- assignUFArrayIf varEnc
                            (\iLit -> mkApp varFun [xp1, iLit])
                            (\iLit eq -> do
                                iLitNeq <- mkNot =<< mkEq iLit castIdx
                                mkImplies iLitNeq eq
                            )
                            xLit
                case maybeRhs of
                  Just rhs -> do
                    evalRhs <- evalExpr varEncVec rhs xLit
                    idxEq <- mkEq evalRhs =<< mkApp varFun [xp1, castIdx]
                    mkAnd [idxEq, propRest]
                  Nothing -> return propRest
              Scalar -> error "Unexpected scalar variable."

      case action of
        MP.Noop -> propvals []
        MP.Assign (MP.LScalar lhs) rhs -> do
          let varEnc = varEncVec V.! MP.varId lhs
          -- Do assignment
          evalRhs <- evalExpr varEncVec rhs xLit
          lhsXp1 <- mkApp1 (zVarFun varEnc) xp1
          lhsXp1EqRhs <- mkEq lhsXp1 evalRhs
          -- Propagate all remaining variables
          propagate <- propvals [lhs]
          mkAnd [lhsXp1EqRhs, propagate]
        MP.Assign (MP.LArray var ie) rhs -> do
          arrayStore <- mkArrayStore var ie $ Just rhs
          propagate <- propvals [var]
          mkAnd [arrayStore, propagate]
        MP.Nondet (MP.LScalar var) -> propvals [var]
        MP.Nondet (MP.LArray var ie) -> do
          arrayStore <- mkArrayStore var ie Nothing
          propagate <- propvals [var]
          mkAnd [arrayStore, propagate]
        MP.CallOp fname fargs aargs -> do
          -- Assign parameters
          let assign (farg, aarg) =
                let fVarEnc = varEncVec V.! MP.varId (getFargVar farg)
                in case zVarData fVarEnc of
                  Scalar -> do
                    fxp1 <- mkApp1 (zVarFun fVarEnc) xp1
                    evalAarg <- case aarg of
                      MP.ActualVal e      -> evalExpr varEncVec e xLit
                      MP.ActualValRes var -> mkApp1 (zVarFun $ varEncVec V.! MP.varId var) xLit
                    mkEq fxp1 evalAarg
                  _ -> let avar = case aarg of
                             MP.ActualVal (MP.Term var) -> var
                             MP.ActualValRes var -> var
                             _ -> error "Non-array expression passed as actual array parameter."
                           aVarEnc = varEncVec V.! MP.varId avar
                       in mkVarCopy fVarEnc aVarEnc xLit xp1
          params <- mkAndWith assign $ zip fargs aargs
          -- Initialize to 0 all remaining local variables
          let sk = fnameSksMap M.! fname
              locals = S.toList (MP.skScalars sk) ++ S.toList (MP.skArrays sk)
              remLocals = locals \\ map getFargVar fargs
          initLocals <- mkInit0 varEncVec remLocals xp1
          -- Propagate all remaining variables
          propagate <- propvals locals
          mkAnd [params, initLocals, propagate]
        MP.Return fname fargs aargs -> do
          -- Assign result parameters
          let resArgs = map (\(MP.ValueResult r, MP.ActualValRes t) -> (r, t))
                $ filter (isValRes . fst) $ zip fargs aargs
              assign (r, t) = mkVarCopy (varEncVec V.! MP.varId r) (varEncVec V.! MP.varId t) xLit xp1
          params <- mkAndWith assign resArgs
          -- Restore remaining local variables (they may be overlapping if fname is recursive)
          let sk = fnameSksMap M.! fname
              locals = S.toList (MP.skScalars sk) ++ S.toList (MP.skArrays sk)
              remLocals = locals \\ map snd resArgs
              restore s = let sVarEnc = varEncVec V.! MP.varId s
                          in mkVarCopy sVarEnc sVarEnc xp1 $ fromJust poppedNode
          restoreLocals <- mkAndWith restore remLocals
          -- Propagate all remaining variables
          propagate <- propvals $ map snd resArgs ++ remLocals
          mkAnd [params, restoreLocals, propagate]
      where getFargVar (MP.Value var) = var
            getFargVar (MP.ValueResult var) = var
            isValRes (MP.ValueResult _) = True
            isValRes _ = False
            fnameSksMap = M.fromList . map (\sk -> (MP.skName sk, sk)) . MP.pSks $ zProg progData

    evalBoolExpr :: MonadZ3 z3 => Vector VarEncoder -> MP.Expr -> AST -> z3 AST
    evalBoolExpr varEncVec g xLit = do
      bitSort <- mkBvSort 1
      true <- mkUnsignedInt 1 bitSort
      bvg <- mkBvredor =<< evalExpr varEncVec g xLit
      mkEq bvg true

    evalExpr :: MonadZ3 z3 => Vector VarEncoder -> MP.Expr -> AST -> z3 AST
    evalExpr varEncVec expr x = go expr where
      go e = case e of
        MP.Literal val        -> mkBitvector (BV.size val) (BV.nat val)
        MP.Term var           -> let fv = zVarFun $ varEncVec V.! MP.varId var
                                 in mkApp1 fv x
        MP.ArrayAccess var ie -> do
          let varEnc = varEncVec V.! MP.varId var
              varFun = zVarFun varEnc
          castIdx <- castArrayIndex varEnc =<< go ie
          case zVarData varEnc of
            ArrayTheory {} -> do
              arr <- mkApp1 varFun x
              mkSelect arr castIdx
            UFArray {} -> mkApp varFun [x, castIdx]
            Scalar -> error "Unexpected scalar variable."
        MP.Not b              -> mkBvnot =<< mkBvredor =<< go b
        MP.And b1 b2          -> do
          b1x <- mkBvredor =<< go b1
          b2x <- mkBvredor =<< go b2
          mkBvand b1x b2x
        MP.Or b1 b2           -> do
          b1x <- mkBvredor =<< go b1
          b2x <- mkBvredor =<< go b2
          mkBvor b1x b2x
        MP.Add e1 e2          -> mkBinOp mkBvadd e1 e2
        MP.Sub e1 e2          -> mkBinOp mkBvsub e1 e2
        MP.Mul e1 e2          -> mkBinOp mkBvmul e1 e2
        MP.UDiv e1 e2         -> mkBinOp mkBvudiv e1 e2
        MP.SDiv e1 e2         -> mkBinOp mkBvsdiv e1 e2
        MP.URem e1 e2         -> mkBinOp mkBvurem e1 e2
        MP.SRem e1 e2         -> mkBinOp mkBvsrem e1 e2
        MP.Eq e1 e2           -> mkBvFromBool =<< mkBinOp mkEq e1 e2
        MP.ULt e1 e2          -> mkBvFromBool =<< mkBinOp mkBvult e1 e2
        MP.ULeq e1 e2         -> mkBvFromBool =<< mkBinOp mkBvule e1 e2
        MP.SLt e1 e2          -> mkBvFromBool =<< mkBinOp mkBvslt e1 e2
        MP.SLeq e1 e2         -> mkBvFromBool =<< mkBinOp mkBvsle e1 e2
        MP.UExt w e1          -> mkZeroExt w =<< go e1
        MP.SExt w e1          -> mkSignExt w =<< go e1
        MP.Trunc w e1         -> mkExtract (w - 1) 0 =<< go e1

      mkBinOp op e1 e2 = do
        e1x <- go e1
        e2x <- go e2
        op e1x e2x

      mkBvFromBool b = do
        bitSort <- mkBvSort 1
        true <- mkUnsignedInt 1 bitSort
        false <- mkUnsignedInt 0 bitSort
        mkIte b true false

    castArrayIndex :: MonadZ3 z3 => VarEncoder -> AST -> z3 AST
    castArrayIndex varEnc evalIdx = do
      idxWidth <- getBvSortSize $ case zVarData varEnc of
        ArrayTheory idxSort -> idxSort
        UFArray _ idxSort -> idxSort
        Scalar -> error "Unexpected scalar variable."
      evalIdxWidth <- getBvSortSize =<< getSort evalIdx
      let idxDiff = idxWidth - evalIdxWidth
      if idxDiff < 0
        then mkExtract (idxWidth - 1) 0 evalIdx
        else if idxDiff > 0
             then mkZeroExt idxDiff evalIdx
             else return evalIdx

mkProgAssumptions :: MonadZ3 z3 => EncData -> ProgData -> Word64 -> z3 [AST]
mkProgAssumptions encData progData k = do
  -- Final states
  nodek <- mkUnsignedInt64 k $ zNodeSort encData
  singleton <$> mkOrWith (\l -> do
                             lLit <- mkUnsignedInt l $ zLocSort progData
                             pck <- mkApp1 (zPc progData) nodek
                             mkEq pck lLit
                         ) (zFin progData)

-- push(x), shift(x), pop(x)
mkCheckPrec :: MonadZ3 z3 => EncData -> FuncDecl -> AST -> z3 AST
mkCheckPrec encData precRel x = do
  smbX <- mkApp1 (zSmb encData) x
  structX <- mkApp1 (zStruct encData) x
  mkApp precRel [smbX, structX]


mkApp1 :: MonadZ3 z3 => FuncDecl -> AST -> z3 AST
mkApp1 f x = mkApp f [x]

mkAndWith :: MonadZ3 z3 => (a -> z3 AST) -> [a] -> z3 AST
mkAndWith predGen items = mapM predGen items >>= mkAnd

mkOrWith :: MonadZ3 z3 => (a -> z3 AST) -> [a] -> z3 AST
mkOrWith predGen items = mapM predGen items >>= mkOr

mkForallNodes :: MonadZ3 z3 => [Word64] -> (Word64 -> z3 AST) -> z3 AST
mkForallNodes nodes predGen = mkAndWith predGen nodes

mkExistsNodes :: MonadZ3 z3 => [Word64] -> (Word64 -> z3 AST) -> z3 AST
mkExistsNodes nodes predGen = mkOrWith predGen nodes

closure :: Alphabet MP.ExprProp -> Formula MP.ExprProp
        -> ([Formula MP.ExprProp], [Formula MP.ExprProp])
closure alphabet phi = (structClos, S.toList . S.fromList $ structClos ++ closList phi)
  where
    structClos = map Atomic $ End : (fst alphabet)
    closList f =
      case f of
        T                -> []
        Atomic _         -> [f]
        Not T            -> []
        Not g@(Atomic _) -> [g]
        Not _            -> error "Supplied formula is not in Positive Normal Form."
        Or g h           -> closList g ++ closList h
        And g h          -> closList g ++ closList h
        Xor g h          -> closList g ++ closList h
        Implies g h      -> closList g ++ closList h
        Iff g h          -> closList g ++ closList h
        PNext _ g        -> f : closList g
        PBack _ _        -> error "Past operators not supported yet."
        WPNext _ g       -> f : closList g
        XNext _ g        -> f : closList g
        XBack _ _        -> error "Past operators not supported yet."
        WXNext _ g       -> f : closList g
        HNext _ g        -> f : closList g
        HBack _ _        -> error "Past operators not supported yet."
        WHNext _ g       -> f : closList g
        Until dir g h    -> [f, PNext dir f, XNext dir f] ++ closList g ++ closList h
        Release dir g h  -> [f, WPNext dir f, WXNext dir f] ++ closList g ++ closList h
        Since _ _ _      -> error "Past operators not supported yet."
        HUntil dir g h   -> [f, HNext dir f, HUntil dir T T] ++ closList g ++ closList h
        HRelease dir g h -> [f, WHNext dir f, HUntil dir T T] ++ closList g ++ closList h
        HSince _ _ _     -> error "Past operators not supported yet."
        Next g           -> f : closList g
        WNext g          -> f : closList g
        Back g           -> f : closList g
        WBack g          -> f : closList g
        Eventually g     -> [f, Next f] ++ closList g
        Always g         -> [f, WNext f] ++ closList g
        Once g           -> [f, Back f] ++ closList g
        Historically g   -> [f, WBack f] ++ closList g
        AuxBack _ _      -> error "AuxBack not supported in SMT encoding."

xnf :: Formula MP.ExprProp -> Formula MP.ExprProp
xnf f = case f of
  T                -> f
  Atomic _         -> f
  Not T            -> f
  Not (Atomic _)   -> f
  Not _            -> error "Supplied formula is not in Positive Normal Form."
  Or g h           -> Or (xnf g) (xnf h)
  And g h          -> And (xnf g) (xnf h)
  Xor g h          -> Xor (xnf g) (xnf h)
  Implies g h      -> Implies (xnf g) (xnf h)
  Iff g h          -> Iff (xnf g) (xnf h)
  PNext _ _        -> f
  PBack _ _        -> error "Past operators not supported yet."
  WPNext _ _       -> f
  XNext _ _        -> f
  XBack _ _        -> error "Past operators not supported yet."
  WXNext _ _       -> f
  HNext _ _        -> f
  HBack _ _        -> error "Past operators not supported yet."
  WHNext _ _       -> f
  Until dir g h    -> xnf h `Or` (xnf g `And` (PNext dir f `Or` XNext dir f))
  Release dir g h  -> xnf h `And` (xnf g `Or` (WPNext dir f `And` WXNext dir f))
  Since _ _ _      -> error "Past operators not supported yet."
  HUntil dir g h   -> (HUntil dir T T `And` xnf h) `Or` (xnf g `And` (HNext dir f))
  HRelease dir g h -> (HUntil dir T T `Implies` xnf h) `And` (xnf g `Or` WHNext dir f)
  HSince _ _ _     -> error "Past operators not supported yet."
  Next _           -> f
  WNext _          -> f
  Back _           -> f
  WBack _          -> f
  Eventually g     -> xnf g `Or` Next f
  Always g         -> xnf g `And` WNext f
  Once g           -> xnf g `Or` Back f
  Historically g   -> xnf g `And` WBack f
  AuxBack _ _      -> error "AuxBack not supported in SMT encoding."


queryTableau :: (MonadFail z3, MonadZ3 z3) => EncData -> Word64 -> Maybe Word64 -> Model -> z3 [TableauNode]
queryTableau encData k maxLen model = do
  let unrollLength = case maxLen of
        Just ml -> min k ml
        Nothing -> k
  mapM queryTableauNode [0..unrollLength]
  where
    fConstList = M.toList $ zFConstMap encData
    constPropMap = M.fromList $ map (\(Atomic p, fConst) -> (fConst, p))
                   $ filter (atomic . fst) fConstList
    queryTableauNode idx = do
      idxNode <- mkUnsignedInt64 idx $ zNodeSort encData
      gammaVals <- filterM (\(_, fConst) -> fromJust <$>
                             (evalBool model =<< mkApp (zGamma encData) [fConst, idxNode])) fConstList
      Just smbVal <- eval model =<< mkApp1 (zSmb encData) idxNode
      Just stackVal <- evalInt model =<< mkApp1 (zStack encData) idxNode
      Just ctxVal <- evalInt model =<< mkApp1 (zCtx encData) idxNode
      return TableauNode { nodeGammaC = map fst gammaVals
                         , nodeSmb = constPropMap M.! smbVal
                         , nodeStack = stackVal
                         , nodeCtx = ctxVal
                         , nodeIdx = fromIntegral idx
                         }

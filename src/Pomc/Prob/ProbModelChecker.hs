{- |
   Module      : Pomc.Prob.ProbModelChecker
   Copyright   : 2023-2025 Francesco Pontiggia
   License     : MIT
   Maintainer  : Francesco Pontiggia
-}

module Pomc.Prob.ProbModelChecker ( ExplicitPopa(..)
                                  -- APIs
                                  , programTermination
                                  , qualitativeModelCheckProgram
                                  , quantitativeModelCheckProgram
                                  -- testing APIs
                                  , terminationLTExplicit
                                  , terminationLEExplicit
                                  , terminationGTExplicit
                                  , terminationGEExplicit
                                  , terminationApproxExplicit
                                  , qualitativeModelCheckExplicit
                                  , qualitativeModelCheckExplicitGen
                                  , quantitativeModelCheckExplicit
                                  , quantitativeModelCheckExplicitGen
                                  , exportMarkovChain
                                  ) where

import Pomc.Prop (Prop(..))
import Pomc.Prec (Alphabet)
import Pomc.Potl (Formula(..), getProps, normalize)
import Pomc.Check(makeOpa, InitialsComputation(..))
import Pomc.PropConv (APType, convProps, PropConv(encodeProp, decodeAP), encodeFormula)
import Pomc.TimeUtils (startTimer, stopTimer)
import Pomc.LogUtils (MonadLogger, logDebugN, logInfoN)
import qualified Pomc.Encoding as E

import Pomc.Prob.SupportGraph (buildSupportGraph)
import qualified Pomc.Prob.GGraph as GG
import qualified Pomc.Prob.ProbEncoding as PE
import Pomc.Prob.Z3Termination (terminationQuerySCC)
import Pomc.Prob.ProbUtils hiding (sIdMap)
import Pomc.Prob.MiniProb (Program, programToPopa, Popa(..), ExprProp)

import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.IntSet as IntSet
import qualified Data.Map as Map

import Data.Bifunctor(second)

import Data.Hashable (Hashable)
import Control.Monad.IO.Class (MonadIO)

import Pomc.Z3T
import Z3.Monad (Logic(..))
import Z3.Opts

import qualified Data.Vector as V
import Data.STRef (newSTRef, readSTRef)
import Numeric (showEFloat)

-- import qualified Debug.Trace as DBG

data ExplicitPopa s a = ExplicitPopa
  { epAlphabet       :: Alphabet a -- OP alphabet
  , epInitial        :: (s, Set (Prop a)) -- initial state of the POPA
  , epopaDeltaPush   :: [(s, RichDistr s (Set (Prop a)))] -- push transition prob. distribution
  , epopaDeltaShift  :: [(s, RichDistr s (Set (Prop a)))] -- shift transition prob. distribution
  , epopaDeltaPop    :: [(s, s, RichDistr s (Set (Prop a)))] -- pop transition prob. distribution
  } deriving (Show)

-- TERMINATION
-- is the probability to terminate respectively <, <=, >=, > than the given probability?
-- (the return String is a debugging message for developing purposes)
terminationLTExplicit :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s, Ord a)
                      => ExplicitPopa s a -> Prob -> Solver -> m (Bool, Stats, String)
terminationLTExplicit popa bound solv = (\(res, s, str) -> (toBool res, s, str)) <$> terminationExplicit (CompQuery Lt bound solv) popa

terminationLEExplicit :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s, Ord a)
                      => ExplicitPopa s a -> Prob -> Solver -> m (Bool, Stats, String)
terminationLEExplicit popa bound solv = (\(res, s, str) -> (toBool res, s, str)) <$> terminationExplicit (CompQuery Le bound solv) popa

terminationGTExplicit :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s, Ord a)
                      => ExplicitPopa s a -> Prob -> Solver -> m (Bool, Stats, String)
terminationGTExplicit popa bound solv = (\(res, s, str) -> (toBool res, s, str)) <$> terminationExplicit (CompQuery Gt bound solv) popa

terminationGEExplicit :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s, Ord a)
                      => ExplicitPopa s a -> Prob -> Solver -> m (Bool, Stats, String)
terminationGEExplicit popa bound solv = (\(res, s, str) -> (toBool res, s, str)) <$> terminationExplicit (CompQuery Ge bound solv) popa

-- what is the probability that the input POPA terminates?
terminationApproxExplicit :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s, Ord a)
                          => ExplicitPopa s a -> Solver -> m ((Prob, Prob), Stats, String)
terminationApproxExplicit popa solv = (\(ApproxSingleResult res, s, str) -> (res, s, str)) <$> terminationExplicit (ApproxSingleQuery solv) popa

terminationExplicit :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s, Ord a)
                    => TermQuery
                    -> ExplicitPopa s a
                    -> m (TermResult, Stats, String)
terminationExplicit query popa =
  let
    (sls, prec) = epAlphabet popa
    (_, tprec, [tsls], pconv) = convProps T prec [sls]

    -- I don't actually care, I just need the bitenc
    (bitenc, precFunc, _, _, _, _, _, _) =
      makeOpa T IsProb (tsls, tprec) (\_ _ -> True)

    maybeList Nothing = []
    maybeList (Just l) = l

    -- generate the delta relation of the input opa
    encodeDistr = map (\(s, b, p) -> (s, E.encodeInput bitenc (Set.map (encodeProp pconv) b), p))
    makeDeltaMapI delta = Map.fromListWith (++) $
      map (\(q, distr) -> (q, encodeDistr  distr))
          delta
    deltaPush  = makeDeltaMapI  (epopaDeltaPush popa)
    deltaShift  = makeDeltaMapI  (epopaDeltaShift popa)
    popaDeltaPush  q = maybeList $ Map.lookup q deltaPush
    popaDeltaShift  q = maybeList $ Map.lookup q deltaShift

    makeDeltaMapS  delta = Map.fromListWith (++) $
      map (\(q, q', distr) -> ((q, q'), encodeDistr  distr))
          delta
    deltaPop = makeDeltaMapS   (epopaDeltaPop popa)
    popaDeltaPop  q q' = maybeList $ Map.lookup (q, q') deltaPop

    pDelta = Delta
            { bitenc = bitenc
            , proBitenc = error "proBitenc used in pOPA termination"
            , prec = precFunc
            , deltaPush = popaDeltaPush
            , deltaShift = popaDeltaShift
            , deltaPop = popaDeltaPop
            , phiDeltaPush = error "phiDeltaPush used in pOPA termination"
            , phiDeltaShift = error "phiDeltaShift used in pOPA termination"
            , phiDeltaPop = error "phiDeltaPop used in pOPA termination"
            }
  in do
    stats <- liftSTtoIO $ newSTRef newStats
    (sc, _) <- liftSTtoIO $ buildSupportGraph pDelta (fst . epInitial $ popa, E.encodeInput bitenc . Set.map (encodeProp pconv) . snd . epInitial $ popa) stats

    (res, _) <- evalZ3TWith (chooseLogic $ solver query) stdOpts
      $ terminationQuerySCC sc precFunc query stats
    logInfoN $ "Computed termination probability: " ++ show res
    computedStats <- liftSTtoIO $ readSTRef stats
    return (res, computedStats, show sc)

-- what is the probability that the input MiniProb program terminates?
programTermination :: (MonadIO m, MonadFail m, MonadLogger m)
                   => Solver -> Program -> m (TermResult, Stats, String)
programTermination solv prog =
  let (_, _, popa) = programToPopa prog Set.empty
      (tsls, tprec) = popaAlphabet popa
      (bitenc, precFunc, _, _, _, _, _, _) =
        makeOpa T IsProb (tsls, tprec) (\_ _ -> True)

      initial = popaInitial popa bitenc
      pDelta = Delta
               { bitenc = bitenc
               , proBitenc = error "proBitenc used in program termination"
               , prec = precFunc
               , deltaPush = popaDeltaPush popa bitenc
               , deltaShift = popaDeltaShift popa bitenc
               , deltaPop = popaDeltaPop popa bitenc
               , phiDeltaPush = error "phiDeltaPush used in program termination"
               , phiDeltaShift = error "phiDeltaShift used in program termination"
               , phiDeltaPop = error "phiDeltaPop used in program termination"
               }

  in do
    stats <- liftSTtoIO $ newSTRef newStats
    (sc, _) <- liftSTtoIO $ buildSupportGraph pDelta initial stats
    (res, _) <- evalZ3TWith (chooseLogic solv) stdOpts
      $ terminationQuerySCC sc precFunc (ApproxSingleQuery solv) stats
    logInfoN $ "Computed termination probabilities: " ++ show res
    computedStats <- liftSTtoIO $ readSTRef stats
    return (res, computedStats, show sc)

-- QUALITATIVE MODEL CHECKING
-- is the probability that the POPA satisfies phi equal to 1?
qualitativeModelCheck :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s)
                      => Solver
                      -> Formula APType -- input formula phi to check
                      -> Alphabet APType -- structural OP alphabet
                      -> (E.BitEncoding -> (s, Label)) -- POPA initial states
                      -> (E.BitEncoding -> s -> RichDistr s Label) -- POPA Delta Push
                      -> (E.BitEncoding -> s -> RichDistr s Label) -- POPA Delta Shift
                      -> (E.BitEncoding -> s -> s -> RichDistr s Label) -- POPA Delta Pop
                      -> m (Bool, Stats, String)
qualitativeModelCheck solv phi alphabet bInitials bDeltaPush bDeltaShift bDeltaPop =
  let
    (bitenc, precFunc, phiInitials, (_, phiIsFinalW), phiDeltaPush, phiDeltaShift, phiDeltaPop, cl) =
      makeOpa phi IsProb alphabet (\_ _ -> True)

    proEnc = PE.makeProBitEncoding cl phiIsFinalW
    phiPush p = (phiDeltaPush p Nothing)
    phiShift p = (phiDeltaShift p Nothing)

    wrapper = Delta
      { bitenc = bitenc
      , proBitenc = proEnc
      , prec = precFunc
      , deltaPush = bDeltaPush bitenc
      , deltaShift = bDeltaShift bitenc
      , deltaPop = bDeltaPop bitenc
      , phiDeltaPush = phiPush
      , phiDeltaShift = phiShift
      , phiDeltaPop = phiDeltaPop
      }
  in do
    stats <- liftSTtoIO $ newSTRef newStats
    (sc, sIdMap) <- liftSTtoIO $ buildSupportGraph wrapper (bInitials bitenc) stats
    logInfoN $ "Size of the Support Graph: " ++ show (V.length sc)
    (ApproxAllResult (_, ubMap), mustReachPopIdxs) <- evalZ3TWith (chooseLogic solv) stdOpts
      $ terminationQuerySCC sc precFunc (ApproxAllQuery solv) stats
    let ubTermMap = Map.mapKeysWith (+) fst ubMap
        ubVec =  V.generate (V.length sc) (\idx -> Map.findWithDefault 0 idx ubTermMap)
        cases i k
          | k < (1 - 100 * defaultRTolerance) && IntSet.member i mustReachPopIdxs =
            -- inconsistent result
            error $ "semiconf " ++ show i ++ "has a PAST certificate with termination probability equal to" ++ show k
          | k < (1 - 100 * defaultRTolerance) = True
          | IntSet.member i mustReachPopIdxs = False
          | otherwise = error $ "Semiconf " ++ show i ++ " has termination probability " ++ show k
                        ++ " but it is not certified to be PAST." -- inconclusive result
        pendVector = V.imap cases ubVec
    logDebugN $ "Computed termination probabilities: " ++ show ubVec
    logDebugN $ "Pending Vector: " ++ show pendVector
    logInfoN "Conclusive analysis!"
    logInfoN $ "Size of the Support Chain: " ++ show (V.foldl (flip ((+) . fromEnum)) 0 pendVector)
    computedStats <- liftSTtoIO $ readSTRef stats
    logInfoN $ "Stats so far: " ++ concat [
        "Times: "
      , showEFloat (Just 4) (upperBoundTime computedStats) " s (upper bounds), "
      , showEFloat (Just 4) (pastTime computedStats) " s (PAST certificates), "
      , "\nInput pOPA state count: ", show $ popaStatesCount computedStats
      , "\nSupport graph size: ", show $ suppGraphLen computedStats
      , "\nEquations solved for termination probabilities: ", show $ equationsCount computedStats
      , "\nNon-trivial equations solved for termination probabilities: ", show $ nonTrivialEquationsCount computedStats
      , "\nSCC count in the support graph: ", show $ sccCount computedStats
      , "\nSize of the largest SCC in the support graph: ", show $ largestSCCSemiconfsCount computedStats
      , "\nLargest number of non trivial equations in an SCC in the Support Graph: ", show $ largestSCCNonTrivialEqsCount computedStats
      ]

    startGGTime <- startTimer
    almostSurely <- GG.qualitativeModelCheck wrapper (normalize phi) phiInitials sc sIdMap pendVector stats
    tGG <- stopTimer startGGTime almostSurely

    updatedStats <- liftSTtoIO $ readSTRef stats
    return (almostSurely, updatedStats { gGraphTime = tGG }, show sc ++ show pendVector)

qualitativeModelCheckProgram :: (MonadIO m, MonadFail m, MonadLogger m)
                             => Solver
                             -> Formula ExprProp -- phi: input formula to check
                             -> Program -- input program
                             -> m (Bool, Stats, String)
qualitativeModelCheckProgram solv phi prog =
  let
    (pconv, _, popa) = programToPopa prog (Set.fromList $ getProps phi)
    transPhi = encodeFormula pconv phi
  in qualitativeModelCheck solv transPhi (popaAlphabet popa) (popaInitial popa) (popaDeltaPush popa) (popaDeltaShift popa) (popaDeltaPop popa)

qualitativeModelCheckExplicit :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s)
                              => Solver
                              -> Formula APType -- phi: input formula to check
                              -> ExplicitPopa s APType -- input OPA
                              -> m (Bool, Stats, String)
qualitativeModelCheckExplicit solv phi popa =
  let
    -- all the structural labels + all the labels which appear in phi
    essentialAP = Set.fromList $ End : (fst $ epAlphabet popa) ++ (getProps phi)

    maybeList Nothing = []
    maybeList (Just l) = l

    -- generate the delta relation of the input opa
    encodeDistr bitenc = map (\(s, b, p) -> (s, E.encodeInput bitenc (Set.intersection essentialAP b), p))
    makeDeltaMapI delta bitenc = Map.fromListWith (++) $
      map (\(q, distr) -> (q, encodeDistr bitenc distr))
          delta
    deltaPush  = makeDeltaMapI  (epopaDeltaPush popa)
    deltaShift  = makeDeltaMapI  (epopaDeltaShift popa)
    popaDeltaPush bitenc q = maybeList $ Map.lookup q (deltaPush bitenc)
    popaDeltaShift bitenc q = maybeList $ Map.lookup q (deltaShift bitenc)

    makeDeltaMapS delta bitenc = Map.fromListWith (++) $
      map (\(q, q', distr) -> ((q, q'), encodeDistr bitenc distr))
          delta
    deltaPop = makeDeltaMapS (epopaDeltaPop popa)
    popaDeltaPop bitenc q q' = maybeList $ Map.lookup (q, q') (deltaPop bitenc)

    initial bitenc = (fst . epInitial $ popa, E.encodeInput bitenc . Set.intersection essentialAP . snd .  epInitial $ popa)
  in qualitativeModelCheck solv phi (epAlphabet popa) initial popaDeltaPush popaDeltaShift popaDeltaPop


qualitativeModelCheckExplicitGen :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s, Ord a)
                                 => Solver
                                 -> Formula a -- phi: input formula to check
                                 -> ExplicitPopa s a -- input OPA
                                 -> m (Bool, Stats, String)
qualitativeModelCheckExplicitGen solv phi popa =
  let
    (sls, prec) = epAlphabet popa
    essentialAP = Set.fromList $ End : sls ++ getProps phi
    (tphi, tprec, [tsls], pconv) = convProps phi prec [sls]
    transDelta = map (second
                        (map (\(a, b, p) ->
                            (a, Set.map (encodeProp pconv) $ Set.intersection essentialAP b, p))
                        )
                     )
    transDeltaPop = map ( \(q,q0, distr) -> (q,q0,
                                                  map (\(a, b, p) ->
                                                    (a, Set.map (encodeProp pconv) $ Set.intersection essentialAP b, p))
                                                  distr
                                            )
                        )
    transInitial = second (Set.map (encodeProp pconv) . Set.intersection essentialAP)
    tPopa = popa { epAlphabet   = (tsls, tprec)
                , epInitial = transInitial (epInitial popa)
                 , epopaDeltaPush  = transDelta (epopaDeltaPush popa)
                 , epopaDeltaShift = transDelta (epopaDeltaShift popa)
                 , epopaDeltaPop = transDeltaPop (epopaDeltaPop popa)
                 }
  in qualitativeModelCheckExplicit solv tphi tPopa


-- QUANTITATIVE MODEL CHECKING
-- what is the probability that the POPA satisfies phi?
quantitativeModelCheck :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s)
                       => Solver
                       -> Formula APType -- input formula phi
                       -> Alphabet APType -- structural OP alphabet
                       -> (E.BitEncoding -> (s, Label)) -- POPA initial states
                       -> (E.BitEncoding -> s -> RichDistr s Label) -- POPA Delta Push
                       -> (E.BitEncoding -> s -> RichDistr s Label) -- POPA Delta Shift
                       -> (E.BitEncoding -> s -> s -> RichDistr s Label) -- POPA Delta Pop
                       -> m ((Prob,Prob), Stats, String)
quantitativeModelCheck solv phi alphabet bInitials bDeltaPush bDeltaShift bDeltaPop =
  let
    (bitenc, precFunc, phiInitials, (_, phiIsFinalW), phiDeltaPush, phiDeltaShift, phiDeltaPop, cl) =
      makeOpa phi IsProb alphabet (\_ _ -> True)

    proEnc = PE.makeProBitEncoding cl phiIsFinalW
    phiPush p = (phiDeltaPush p Nothing)
    phiShift p = (phiDeltaShift p Nothing)

    wrapper = Delta
      { bitenc = bitenc
      , proBitenc = proEnc
      , prec = precFunc
      , deltaPush = bDeltaPush bitenc
      , deltaShift = bDeltaShift bitenc
      , deltaPop = bDeltaPop bitenc
      , phiDeltaPush = phiPush
      , phiDeltaShift = phiShift
      , phiDeltaPop = phiDeltaPop
      }

  in do
    stats <- liftSTtoIO $ newSTRef newStats
    (supportChain, sIdMap) <- liftSTtoIO $ buildSupportGraph wrapper (bInitials bitenc) stats
    logInfoN $ "Size of the Support Graph: " ++ show (V.length supportChain)
    (ApproxAllResult (lbProbs, ubProbs), mustReachPopIdxs) <- evalZ3TWith (Just QF_LRA) stdOpts
      $ terminationQuerySCC supportChain precFunc (ApproxAllQuery solv) stats
    let ubTermMap = Map.mapKeysWith (+) fst ubProbs
        ubVec =  V.generate (V.length supportChain) (\idx -> Map.findWithDefault 0 idx ubTermMap)
        cases i k
          | k < (1 - 100 * defaultRTolerance) && IntSet.member i mustReachPopIdxs =
            -- inconsistent result
            error $ "semiconf " ++ show i ++ "has a PAST certificate with termination probability equal to" ++ show k
          | k < (1 - 100 * defaultRTolerance) = True
          | IntSet.member i mustReachPopIdxs = False
          | otherwise = error $ "Semiconf " ++ show i ++ " has termination probability " ++ show k
                        ++ " but it is not certified to be PAST." -- inconclusive result
        pendVector = V.imap cases ubVec
    logInfoN $ "Computed upper bounds on termination probabilities: " ++ show ubVec
    logDebugN $ "Pending Upper Bounds Vector: " ++ show pendVector
    logInfoN "Conclusive analysis!"
    logInfoN $ "Size of the Support Chain: " ++ show (V.foldl (flip ((+) . fromEnum)) 0 pendVector)

    (ub, lb) <- GG.quantitativeModelCheck wrapper (normalize phi) phiInitials supportChain pendVector lbProbs ubProbs sIdMap stats solv
    computedStats <- liftSTtoIO $ readSTRef stats
    return ((ub, lb), computedStats, show supportChain ++ show pendVector)

quantitativeModelCheckProgram :: (MonadIO m, MonadFail m, MonadLogger m)
                              => Solver
                              -> Formula ExprProp -- phi: input formula to check
                              -> Program -- input program
                              -> m ((Prob, Prob), Stats, String)
quantitativeModelCheckProgram solv phi prog =
  let
    (pconv, _, popa) = programToPopa prog (Set.fromList $ getProps phi)
    transPhi = encodeFormula pconv phi
  in quantitativeModelCheck solv transPhi (popaAlphabet popa) (popaInitial popa) (popaDeltaPush popa) (popaDeltaShift popa) (popaDeltaPop popa)

quantitativeModelCheckExplicit :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s)
                               => Solver
                               -> Formula APType -- phi: input formula to check
                               -> ExplicitPopa s APType -- input OPA
                               -> m ((Prob,Prob), Stats, String)
quantitativeModelCheckExplicit solv phi popa =
  let
    -- all the structural labels + all the labels which appear in phi
    essentialAP = Set.fromList $ End : (fst $ epAlphabet popa) ++ (getProps phi)

    maybeList Nothing = []
    maybeList (Just l) = l

    -- generate the delta relation of the input opa
    encodeDistr bitenc = map (\(s, b, p) -> (s, E.encodeInput bitenc (Set.intersection essentialAP b), p))
    makeDeltaMapI delta bitenc = Map.fromListWith (++) $
      map (\(q, distr) -> (q, encodeDistr bitenc distr))
          delta
    deltaPush  = makeDeltaMapI  (epopaDeltaPush popa)
    deltaShift  = makeDeltaMapI  (epopaDeltaShift popa)
    popaDeltaPush bitenc q = maybeList $ Map.lookup q (deltaPush bitenc)
    popaDeltaShift bitenc q = maybeList $ Map.lookup q (deltaShift bitenc)

    makeDeltaMapS delta bitenc = Map.fromListWith (++) $
      map (\(q, q', distr) -> ((q, q'), encodeDistr bitenc distr))
          delta
    deltaPop = makeDeltaMapS (epopaDeltaPop popa)
    popaDeltaPop bitenc q q' = maybeList $ Map.lookup (q, q') (deltaPop bitenc)

    initial bitenc = (fst . epInitial $ popa, E.encodeInput bitenc . Set.intersection essentialAP . snd .  epInitial $ popa)
  in quantitativeModelCheck solv phi (epAlphabet popa) initial popaDeltaPush popaDeltaShift popaDeltaPop


quantitativeModelCheckExplicitGen :: (MonadIO m, MonadFail m, MonadLogger m, Ord s, Hashable s, Show s, Ord a)
                                  => Solver
                                  -> Formula a -- phi: input formula to check
                                  -> ExplicitPopa s a -- input OPA
                                  -> m ((Prob, Prob), Stats, String)
quantitativeModelCheckExplicitGen solv phi popa =
  let
    (sls, prec) = epAlphabet popa
    essentialAP = Set.fromList $ End : sls ++ getProps phi
    (tphi, tprec, [tsls], pconv) = convProps phi prec [sls]
    transDelta = map (second
                        (map (\(a, b, p) ->
                            (a, Set.map (encodeProp pconv) $ Set.intersection essentialAP b, p))
                        )
                     )
    transDeltaPop = map ( \(q,q0, distr) -> (q,q0,
                                                  map (\(a, b, p) ->
                                                    (a, Set.map (encodeProp pconv) $ Set.intersection essentialAP b, p))
                                                  distr
                                            )
                        )
    transInitial = second (Set.map (encodeProp pconv) . Set.intersection essentialAP)
    tPopa = popa { epAlphabet   = (tsls, tprec)
                , epInitial = transInitial (epInitial popa)
                 , epopaDeltaPush  = transDelta (epopaDeltaPush popa)
                 , epopaDeltaShift = transDelta (epopaDeltaShift popa)
                 , epopaDeltaPop = transDeltaPop (epopaDeltaPop popa)
                 }
  in quantitativeModelCheckExplicit solv tphi tPopa

chooseLogic :: Solver -> Maybe Logic
chooseLogic (OVI _) = Just QF_LRA
chooseLogic _ = Just QF_NRA

-- export a Markov Chain representation of the pOPA with unfolded stack up to depth = bound
exportMarkovChain :: (MonadIO m, MonadFail m, MonadLogger m)
            => Formula ExprProp -- phi: input formula to keep track of symbols
            -> Program -- input program
            -> Int -- a bound on stack's depth
            -> FilePath
            -> FilePath
            -> m ()
exportMarkovChain phi prog depth transFile labFile =
  let
    (pconv, _, popa) = programToPopa prog (Set.fromList $ getProps phi)
    transPhi = encodeFormula pconv phi
    (bitencPhi, precFunc, _, (_, _), _, _, _, _) =
      makeOpa transPhi IsProb (popaAlphabet popa) (\_ _ -> True)


    initial = (popaInitial popa) bitencPhi

    -- some are not initialized because they are not needed
    wrapper = Delta
      { bitenc = bitencPhi
      , prec = precFunc
      , deltaPush = (popaDeltaPush popa) bitencPhi
      , deltaShift = (popaDeltaShift popa) bitencPhi
      , deltaPop = (popaDeltaPop popa) bitencPhi
      }
  in do
    logInfoN $ "Max depth: " ++ show depth
    showFlatModel wrapper initial (decodeAP pconv) depth transFile labFile

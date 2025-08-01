{- |
   Module      : Pomc.Prob.SupportGraph
   Copyright   : 2023-2025 Francesco Pontiggia
   License     : MIT
   Maintainer  : Francesco Pontiggia
-}

module Pomc.Prob.SupportGraph ( SupportGraph
                              , buildSupportGraph
                              , asPendingSemiconfs
                              , GraphNode(..)
                              , Edge(..)
                              ) where
import Pomc.Prob.ProbUtils
import Pomc.Prec (Prec(..))

import qualified Pomc.CustoMap as CM

import Pomc.SetMap(SetMap)
import qualified Pomc.SetMap as SM

import Pomc.GStack(GStack)
import qualified Pomc.GStack as GS

import Data.Set(Set)
import qualified Data.Set as Set

import Data.IntSet(IntSet)
import qualified Data.IntSet as IntSet

import Data.Strict.Map(Map)

import qualified Data.Vector.Mutable as MV

import Data.IntMap.Strict(IntMap)
import qualified Data.IntMap.Strict as Map

import Control.Monad(forM, forM_, when, unless)

import Control.Monad.ST (ST)
import Data.STRef (STRef, newSTRef, readSTRef, modifySTRef')

import Data.Maybe (fromJust, isNothing)

import Data.Hashable (Hashable)

import Data.Vector (Vector)
import qualified Data.Vector as V

import qualified Data.HashTable.ST.Basic as BH
-- a basic open-addressing hashtable using linear probing
-- s = thread state, k = key, v = value.
type HashTable s k v = BH.HashTable s k v

data Edge = Edge
  { to    :: Int
  , prob  :: Prob
  } deriving Show

instance Eq Edge where
  p == q = (to p) == (to q)

instance Ord Edge where
  compare p q = compare (to p) (to q)

-- a node in the support graph, corresponding to a semiconfiguration
data GraphNode state = GraphNode
  { gnId   :: Int
  , semiconf   :: (StateId state, Stack state)
  , internalEdges :: Set Edge
  , supportEdges  :: Set Edge
  -- if the semiconf is a pop one, then popContexts represents the probability distribution of the pop transition 
  , popContexts :: IntMap Prob
  } deriving Show

instance Eq (GraphNode state) where
  p == q =  gnId p ==  gnId q

instance  Ord (GraphNode state) where
  compare r q = compare ( gnId r) ( gnId q)

-- the Support Graph computed by this module
type PartialSupportGraph s state = CM.CustoMap s (GraphNode state)
type SupportGraph state = Vector (GraphNode state)
type SidMap state = Map state Int

-- the global variables in the algorithm
data Globals s state = Globals
  { sIdGen     :: SIdGen s state
  , idSeq      :: STRef s Int
  , graphMap   :: HashTable s (Int,Int,Int) Int
  , suppStarts :: STRef s (SetMap s (Stack state))
  , suppEnds   :: STRef s (SetMap s (StateId state))
  , graph      :: STRef s (PartialSupportGraph s state)
  }

buildSupportGraph  :: (Ord state, Hashable state, Show state)
        => DeltaWrapper state -- probabilistic delta relation of a popa
        -> (state, Label) -- (initial state of the popa, label of the initial state)
        -> STRef s Stats
        -> ST s (SupportGraph state, SidMap state) -- returning a graph
buildSupportGraph probdelta (i, iLabel) stats = do
  -- initialize the global variables
  newSig <- initSIdGen
  emptySuppStarts <- SM.empty
  emptySuppEnds <- SM.empty
  initialsId <- wrapState newSig i iLabel
  let initialNode = (initialsId, Nothing)
  newIdSequence <- newSTRef (0 :: Int)
  emptyGraphMap <- BH.new
  emptyGraph <- CM.empty
  initialId <- freshPosId newIdSequence
  BH.insert emptyGraphMap (decode initialNode) initialId
  CM.insert emptyGraph initialId $ GraphNode {gnId=initialId, semiconf=initialNode, internalEdges= Set.empty, supportEdges = Set.empty, popContexts = Map.empty}
  let globals = Globals { sIdGen = newSig
                        , idSeq = newIdSequence
                        , graphMap = emptyGraphMap
                        , suppStarts = emptySuppStarts
                        , suppEnds = emptySuppEnds
                        , graph = emptyGraph
                        }
  -- compute the support graph of the input popa
  build globals probdelta initialNode
  idx <- readSTRef . idSeq $ globals
  statesCount <- sIdCount newSig
  modifySTRef' stats $ \s -> s{suppGraphLen = idx}
  modifySTRef' stats $ \s -> s{popaStatesCount = statesCount}
  suppGraph <- V.freeze . CM.take idx =<< (readSTRef . graph $ globals)
  sidMap <- sIdMap (sIdGen globals)
  return (suppGraph, sidMap)

build :: (Eq state, Hashable state, Show state)
      => Globals s state -- global variables of the algorithm
      -> DeltaWrapper state -- delta relation of the popa
      -> (StateId state, Stack state) -- current semiconfiguration
      -> ST s ()
build globals probdelta (q,g) = do
  let qLabel = getLabel q
      qState = getState q
      precRel = (prec probdelta) (fst . fromJust $ g) qLabel
      cases
        -- this case includes the initial push
        | (isNothing g) || precRel == Just Yield =
          buildPush globals probdelta q g qState qLabel

        | precRel == Just Equal =
          buildShift globals probdelta q g qState qLabel

        | precRel == Just Take =
          buildPop globals probdelta q g qState

        | otherwise = return ()
  cases

buildPush :: (Eq state, Hashable state, Show state)
          => Globals s state
          -> DeltaWrapper state
          -> StateId state
          -> Stack state
          -> state
          -> Label
          -> ST s ()
buildPush globals probdelta q g qState qLabel =
  let doPush (p, pLabel, prob_) = do
        newState <- wrapState (sIdGen globals) p pLabel
        buildTransition globals probdelta (q,g) False
          prob_ (newState, Just (qLabel, q))
  in do
    SM.insert (suppStarts globals) (getId q) g
    mapM_ doPush $ (deltaPush probdelta) qState
    currentSuppEnds <- SM.lookup (suppEnds globals) (getId q)
    mapM_ (\s -> buildTransition globals probdelta (q,g) True 0 (s,g))  -- summaries are by default assigned probability zero
      currentSuppEnds

buildShift :: (Eq state, Hashable state, Show state)
           => Globals s state
           -> DeltaWrapper state
           -> StateId state
           -> Stack state
           -> state
           -> Label
           -> ST s ()
buildShift globals probdelta q g qState qLabel =
  let doShift (p, pLabel, prob_)= do
        newState <- wrapState (sIdGen globals) p pLabel
        buildTransition globals probdelta (q,g) False prob_ (newState, Just (qLabel, snd . fromJust $ g))
  in mapM_ doShift $ (deltaShift probdelta) qState

buildPop :: (Eq state, Hashable state, Show state)
         => Globals s state
         -> DeltaWrapper state
         -> StateId state
         -> Stack state
         -> state
         -> ST s ()
buildPop globals probdelta q g qState =
  let doPop (p, pLabel, prob_) =
        let r = snd . fromJust $ g
            closeSupports pwrapped g' = buildTransition globals probdelta (r,g') True prob_ (pwrapped, g')
        in do
          newState <- wrapState (sIdGen globals) p pLabel
          addPopContext globals (q,g) prob_ newState
          SM.insert (suppEnds globals) (getId r) newState
          currentSuppStarts <- SM.lookup (suppStarts globals) (getId r)
          mapM_ (closeSupports newState) currentSuppStarts
  in mapM_ doPop $ (deltaPop probdelta) qState (getState . snd . fromJust $ g)

--
-- functions that modify the stored support graph
--

-- add a right context to a pop semiconfiguration
addPopContext :: (Eq state, Hashable state, Show state)
                => Globals s state
                -> (StateId state, Stack state) -- from state 
                -> Prob
                -> StateId state
                -> ST s ()
addPopContext globals from prob_ rightContext =
  let
    -- we use insertWith + because the input distribution might not be normalized - i.e., there might be duplicate pop transitions
    insertContext g@GraphNode{popContexts= cntxs} =g{popContexts = Map.insertWith (+) (getId rightContext) prob_ cntxs}
  in BH.lookup (graphMap globals) (decode from) >>= CM.modify (graph globals) insertContext . fromJust

-- decomposing a transition to a new semiconfiguration
buildTransition :: (Eq state, Hashable state, Show state)
                 => Globals s state
                 -> DeltaWrapper state
                 -> (StateId state, Stack state) -- from semiconf 
                 -> Bool -- is Support
                 -> Prob
                 -> (StateId state, Stack state) -- to semiconf
                 -> ST s ()
buildTransition globals probdelta from isSupport prob_ dest =
  let
    -- we use sum here to handle non normalized probability distributions (i.e., multiple probabilities to go to the same state, that have to be summed)
    createInternal to_  stored_edges = Edge{to = to_, prob = sum $ prob_ : (Set.toList . Set.map prob . Set.filter (\e -> to e == to_) $ stored_edges)}
    insertEdge to_  True  g@GraphNode{supportEdges = edges_} = g{supportEdges = Set.insert Edge{to = to_, prob = 0} edges_} -- summaries are assigned prob 0 by default
    insertEdge to_  False g@GraphNode{internalEdges = edges_} = g{internalEdges = Set.insert (createInternal to_ edges_) edges_  }
    lookupInsert to_ = BH.lookup (graphMap globals) (decode from) >>= CM.modify (graph globals) (insertEdge to_ isSupport) . fromJust
  in do
    maybeId <- BH.lookup (graphMap globals) (decode dest)
    actualId <- maybe (freshPosId $ idSeq globals) return maybeId
    when (isNothing maybeId) $ do
        BH.insert (graphMap globals) (decode dest) actualId
        CM.insert (graph globals) actualId $ GraphNode {gnId=actualId, semiconf=dest, internalEdges= Set.empty, supportEdges = Set.empty, popContexts = Map.empty}
    lookupInsert actualId
    when (isNothing maybeId) $ build globals probdelta dest


---------------------------------------------------------
-- preprocessing procedures before checking termination for all the semiconfs of a support graph --

-- some renaming to make the algorithm more understandable
type CanReachPop = Bool
type MustReachPop = Bool
type Arch = Int

data DeficientGlobals s state = DeficientGlobals
  { sStack     :: GStack s Arch
  , bStack     :: GStack s Int
  , iVector    :: MV.MVector s Int
  , canReachPop :: MV.MVector s CanReachPop
  , mustReachPop :: MV.MVector s MustReachPop
  }

-- perform the Gabow algorithm to determine semiconfs that cannot reach a pop
-- requires: the initial semiconfiguration is at position 0 in the Support graph
asPendingSemiconfs :: Show state => Vector (GraphNode state) -> ST s (IntSet, IntSet)
asPendingSemiconfs suppGraph = do
  newSS            <- GS.new
  newBS            <- GS.new
  newIVec          <- MV.replicate (V.length suppGraph) 0
  newCanReachPop <- MV.replicate (V.length suppGraph) False
  newMustReachPop <- MV.replicate (V.length suppGraph) False
  let gn = suppGraph V.! 0 -- the initial semiconf
      globals = DeficientGlobals { sStack = newSS
                                 , bStack = newBS
                                 , iVector = newIVec
                                 , canReachPop = newCanReachPop
                                 , mustReachPop = newMustReachPop
                                 }
    
  addtoPath globals gn
  _ <- dfs globals suppGraph gn
  let discardTrues acc _ True = acc
      discardTrues acc idx False = IntSet.insert idx acc
      discardFalses acc idx True = IntSet.insert idx acc
      discardFalses acc _ False = acc
  cannotReachPops <- MV.ifoldl' discardTrues IntSet.empty (canReachPop globals)
  canReachPops <- MV.ifoldl' discardFalses IntSet.empty (canReachPop globals)
  mustReachPops <- MV.ifoldl' discardFalses IntSet.empty (mustReachPop globals)
  unless (IntSet.isSubsetOf mustReachPops canReachPops) $ error "the set of semiconfs that almost surely reach a pop must be a subset of those that may reach a pop"
  return (cannotReachPops, mustReachPops)

dfs :: Show state => DeficientGlobals s state
    -> Vector (GraphNode state)
    -> GraphNode state
    -> ST s (CanReachPop, MustReachPop)
dfs globals suppGraph gn =
  let cases nextNode iVal
        | (iVal == 0) = addtoPath globals nextNode >> dfs globals suppGraph nextNode
        | (iVal < 0)  = do
          crP <- MV.unsafeRead (canReachPop globals) (gnId nextNode)
          mrP <- MV.unsafeRead (mustReachPop globals) (gnId nextNode)
          return (crP, mrP)
        | (iVal > 0)  = merge globals nextNode >> return (False, False)
        | otherwise = error "unreachable error"
      follow e = MV.unsafeRead (iVector globals) (to e) >>= cases (suppGraph V.! (to e))
  in do
    res <- forM (Set.toList $ internalEdges gn) follow
    let dCanReachPop = any fst res
        dMustReachPop = dCanReachPop && all snd res
        computeActualCanReach
          | not . Set.null $ supportEdges gn =  do
            actualRes  <- forM (Set.toList $ supportEdges gn) follow
            return (any fst actualRes, dMustReachPop && all snd actualRes)
          | not . Map.null $ popContexts gn = return (True, True)
          | otherwise = return (dCanReachPop, dMustReachPop)
    canReach <- computeActualCanReach
    createComponent globals gn canReach

-- helpers
addtoPath :: DeficientGlobals s state -> GraphNode state -> ST s ()
addtoPath globals gn = do
  GS.push (sStack globals) (gnId gn)
  sSize <- GS.size $ sStack globals
  MV.unsafeWrite (iVector globals) (gnId gn) sSize
  GS.push (bStack globals) sSize

merge ::  DeficientGlobals s state -> GraphNode state -> ST s ()
merge globals gn = do
  iVal <- MV.unsafeRead (iVector globals) (gnId gn)
  -- contract the B stack, that represents the boundaries between SCCs on the current path
  GS.popWhile_ (bStack globals) (iVal <)


createComponent :: DeficientGlobals s state -> GraphNode state -> (CanReachPop, MustReachPop) -> ST s (CanReachPop, MustReachPop)
createComponent globals gn (canReachP, mustReachP) = do
  topB <- GS.peek $ bStack globals
  iVal <- MV.unsafeRead (iVector globals) (gnId gn)
  if iVal == topB
    then do
      GS.pop_ (bStack globals)
      sSize <- GS.size $ sStack globals
      poppedEdges <- GS.multPop (sStack globals) (sSize - iVal + 1) -- the last one is to gn
      forM_ poppedEdges $ \e -> do
        MV.unsafeWrite (iVector globals) e (-1)
        MV.unsafeWrite (canReachPop globals) e canReachP
        MV.unsafeWrite (mustReachPop globals) e mustReachP
      return (canReachP,mustReachP)
    else return (canReachP, mustReachP)
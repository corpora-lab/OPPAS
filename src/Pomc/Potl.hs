{-# LANGUAGE DeriveGeneric #-}
{- |
   Module      : Pomc.Potl
   Copyright   : 2020-2025 Davide Bergamaschi, Michele Chiari and Francesco Pontiggia
   License     : MIT
   Maintainer  : Michele Chiari
-}

module Pomc.Potl ( Dir(..)
                 , Prop(..)
                 , Formula(..)
                 , transformFold
                 , getProps
                   -- * Predicates on formulas
                 , atomic
                 , negative
                   -- * Operations on formulas
                 , negation
                 , formulaAt
                 , formulaAfter
                 , formulaAtDown
                 , formulaAtUp
                 , normalize
                 , pnf
                 ) where

import Pomc.Prop (Prop(..))
import Data.List (nub, uncons)
import GHC.Generics (Generic)

import Data.Hashable

data Dir = Up | Down deriving (Eq, Ord, Show, Generic)

data Formula a =
  -- Propositional
  T
  | Atomic  (Prop a)
  | Not     (Formula a)
  | Or      (Formula a) (Formula a)
  | And     (Formula a) (Formula a)
  | Xor     (Formula a) (Formula a)
  | Implies (Formula a) (Formula a)
  | Iff     (Formula a) (Formula a)
  -- POTL
  | PNext  Dir (Formula a)
  | PBack  Dir (Formula a)
  | XNext  Dir (Formula a)
  | XBack  Dir (Formula a)
  | HNext  Dir (Formula a)
  | HBack  Dir (Formula a)
  | Until  Dir (Formula a) (Formula a)
  | Since  Dir (Formula a) (Formula a)
  | HUntil Dir (Formula a) (Formula a)
  | HSince Dir (Formula a) (Formula a)
  -- Weak POTL
  | WPNext Dir (Formula a)
  -- | WPBack    Dir (Formula a)
  | WXNext Dir (Formula a)
  -- | WXBack    Dir (Formula a)
  | WHNext Dir (Formula a)
  -- | WHBack    Dir (Formula a)
  | Release Dir (Formula a) (Formula a)
  | HRelease Dir (Formula a) (Formula a)
  -- LTL
  | Next         (Formula a)
  | WNext        (Formula a)
  | Back         (Formula a)
  | WBack        (Formula a)
  | Eventually   (Formula a)
  | Always       (Formula a)
  | Once         (Formula a)
  | Historically (Formula a)
  | GUntil       (Formula a) (Formula a)
  -- Auxiliary
  | AuxBack Dir (Formula a)  -- AuxBack Up is NEVER used
  deriving (Eq, Ord, Generic)

instance (Show a) => Show (Formula a) where
  show f = case f of
    T                 -> showp f
    Atomic _          -> showp f
    Not g             -> concat ["~ ", showp g]
    And g h           -> concat [showp g, " And ",  showp h]
    Or g h            -> concat [showp g, " Or ",   showp h]
    Xor g h           -> concat [showp g, " Xor ",  showp h]
    Implies g h       -> concat [showp g, " --> ",  showp h]
    Iff g h           -> concat [showp g, " <--> ", showp h]
    PNext Down g      -> concat ["PNd ", showp g]
    PNext Up   g      -> concat ["PNu ", showp g]
    PBack Down g      -> concat ["PBd ", showp g]
    PBack Up   g      -> concat ["PBu ", showp g]
    XNext Down g      -> concat ["XNd ", showp g]
    XNext Up   g      -> concat ["XNu ", showp g]
    XBack Down g      -> concat ["XBd ", showp g]
    XBack Up   g      -> concat ["XBu ", showp g]
    HNext Down g      -> concat ["HNd ", showp g]
    HNext Up   g      -> concat ["HNu ", showp g]
    HBack Down g      -> concat ["HBd ", showp g]
    HBack Up   g      -> concat ["HBu ", showp g]
    Until Down g h    -> concat [showp g, " Ud ",  showp h]
    Until Up   g h    -> concat [showp g, " Uu ",  showp h]
    Since Down g h    -> concat [showp g, " Sd ",  showp h]
    Since Up   g h    -> concat [showp g, " Su ",  showp h]
    HUntil Down g h   -> concat [showp g, " HUd ", showp h]
    HUntil Up   g h   -> concat [showp g, " HUu ", showp h]
    HSince Down g h   -> concat [showp g, " HSd ", showp h]
    HSince Up   g h   -> concat [showp g, " HSu ", showp h]
    WPNext Up   g     -> concat ["WPNu ", showp g]
    WPNext Down g     -> concat ["WPNd ", showp g]
    WXNext Up   g     -> concat ["WXNu ", showp g]
    WXNext Down g     -> concat ["WXNd ", showp g]
    WHNext Up   g     -> concat ["WHNu ", showp g]
    WHNext Down g     -> concat ["WHNd ", showp g]
    Release Down g h  -> concat [showp g, " Rd ", showp h]
    Release Up   g h  -> concat [showp g, " Ru ", showp h]
    HRelease Down g h -> concat [showp g, " HRd ", showp h]
    HRelease Up   g h -> concat [showp g, " HRu ", showp h]
    Next g            -> concat ["N ", showp g]
    WNext g           -> concat ["WN ", showp g]
    Back g            -> concat ["B ", showp g]
    WBack g           -> concat ["WB ", showp g]
    Eventually g      -> concat ["F ", showp g]
    Always g          -> concat ["G ", showp g]
    Once g            -> concat ["O ", showp g]
    Historically g    -> concat ["H ", showp g]
    GUntil g h        -> concat [showp g, " U " , showp h]
    AuxBack Down g    -> concat ["AuxBd ", showp g]
    AuxBack Up g      -> concat ["AuxBu ", showp g]
    where showp T = "T"
          showp (Atomic (Prop p)) = show p
          showp (Atomic End) = "#"
          showp g = concat ["(", show g, ")"]

instance Hashable Dir
instance Hashable a => Hashable (Formula a)

instance Functor Formula where
  fmap func f = case f of
    T                -> T
    Atomic p         -> Atomic (fmap func p)
    Not g            -> Not (fmap func g)
    And     g h      -> And     (fmap func g) (fmap func h)
    Or      g h      -> Or      (fmap func g) (fmap func h)
    Xor     g h      -> Xor     (fmap func g) (fmap func h)
    Implies g h      -> Implies (fmap func g) (fmap func h)
    Iff     g h      -> Iff     (fmap func g) (fmap func h)
    PNext dir g      -> PNext dir (fmap func g)
    PBack dir g      -> PBack dir (fmap func g)
    XNext dir g      -> XNext dir (fmap func g)
    XBack dir g      -> XBack dir (fmap func g)
    HNext dir g      -> HNext dir (fmap func g)
    HBack dir g      -> HBack dir (fmap func g)
    Until dir g h    -> Until dir (fmap func g) (fmap func h)
    Since dir g h    -> Since dir (fmap func g) (fmap func h)
    HUntil dir g h   -> HUntil dir (fmap func g) (fmap func h)
    HSince dir g h   -> HSince dir (fmap func g) (fmap func h)
    WPNext dir g     -> WPNext dir (fmap func g)
    WXNext dir g     -> WXNext dir (fmap func g)
    WHNext dir g     -> WHNext dir (fmap func g)
    Release dir g h  -> Release dir (fmap func g) (fmap func h)
    HRelease dir g h -> HRelease dir (fmap func g) (fmap func h)
    Next g           -> Next (fmap func g)
    WNext g          -> WNext (fmap func g)
    Back g           -> Back (fmap func g)
    WBack g          -> WBack (fmap func g)
    Eventually g     -> Eventually (fmap func g)
    Always g         -> Always (fmap func g)
    Once g           -> Once (fmap func g)
    Historically g   -> Historically (fmap func g)
    GUntil g h       -> GUntil (fmap func g) (fmap func h)
    AuxBack dir g    -> AuxBack dir (fmap func g)

transformFold :: (Formula a -> b -> (Formula a, b)) -> b -> Formula a
              -> (Formula a, b)
transformFold t e f = uncurry t $ case f of
  T                -> (f, e)
  Atomic _         -> (f, e)
  Not g            -> goUnary Not g
  Or g h           -> goBinary Or g h
  And g h          -> goBinary And g h
  Xor g h          -> goBinary Xor g h
  Implies g h      -> goBinary Implies g h
  Iff g h          -> goBinary Iff g h
  PNext dir g      -> goUnary (PNext dir) g
  PBack dir g      -> goUnary (PBack dir) g
  WPNext dir g     -> goUnary (WPNext dir) g
  XNext dir g      -> goUnary (XNext dir) g
  XBack dir g      -> goUnary (XBack dir) g
  WXNext dir g     -> goUnary (WXNext dir) g
  HNext dir g      -> goUnary (HNext dir) g
  WHNext dir g     -> goUnary (WHNext dir) g
  HBack dir g      -> goUnary (HBack dir) g
  Until dir g h    -> goBinary (Until dir) g h
  Release dir g h  -> goBinary (Release dir) g h
  Since dir g h    -> goBinary (Since dir) g h
  HUntil dir g h   -> goBinary (HUntil dir) g h
  HRelease dir g h -> goBinary (HRelease dir) g h
  HSince dir g h   -> goBinary (HSince dir) g h
  Next g           -> goUnary Next g
  WNext g          -> goUnary WNext g
  Back g           -> goUnary Back g
  WBack g          -> goUnary WBack g
  Eventually g     -> goUnary Eventually g
  Always g         -> goUnary Always g
  Once g           -> goUnary Once g
  Historically g   -> goUnary Historically g
  GUntil g h       -> goBinary GUntil g h
  AuxBack dir g    -> goUnary (AuxBack dir) g
  where goUnary constr g = let (newG, gRes) = transformFold t e g
                           in (constr newG, gRes)
        goBinary constr g h = let (newG, gRes) = transformFold t e g
                                  (newH, hRes) = transformFold t gRes h
                              in (constr newG newH, hRes)


-- get all the atomic propositions used by a formula, removing duplicates
getProps :: (Eq a) => Formula a -> [Prop a]
getProps formula = nub $ collectProps formula
  where collectProps f = case f of
          T              -> []
          Atomic p       -> [p]
          Not g          -> getProps g
          Or g h         -> getProps g ++ getProps h
          And g h        -> getProps g ++ getProps h
          Xor g h        -> getProps g ++ getProps h
          Implies g h    -> getProps g ++ getProps h
          Iff g h        -> getProps g ++ getProps h
          PNext _ g      -> getProps g
          PBack _ g      -> getProps g
          XNext _ g      -> getProps g
          XBack _ g      -> getProps g
          HNext _ g      -> getProps g
          HBack _ g      -> getProps g
          Until _ g h    -> getProps g ++ getProps h
          Since _ g h    -> getProps g ++ getProps h
          HUntil _ g h   -> getProps g ++ getProps h
          HSince _ g h   -> getProps g ++ getProps h
          WPNext _ g     -> getProps g
          WXNext _ g     -> getProps g
          WHNext _ g     -> getProps g
          Release _ g h  -> getProps g ++ getProps h
          HRelease _ g h -> getProps g ++ getProps h
          Next g         -> getProps g
          WNext g        -> getProps g
          Back g         -> getProps g
          WBack g        -> getProps g
          Eventually g   -> getProps g
          Always g       -> getProps g
          Once g         -> getProps g
          Historically g -> getProps g
          GUntil g h     -> getProps g ++ getProps h
          AuxBack _ g    -> getProps g

atomic :: Formula a -> Bool
atomic (Atomic _) = True
atomic _ = False

negative :: Formula a -> Bool
negative (Not _) = True
negative _ = False

formulaAt :: Int -> Formula a -> Formula a
formulaAt n f
  | n <= 1    = f
  | otherwise = formulaAt (n-1) (Or (PNext Up f) (PNext Down f))
-- TODO: use LTL Next when implemented in explicit-state MC

formulaAfter ::  [Dir] -> Formula a ->  Formula a
formulaAfter l f = case uncons l of
    Nothing -> f
    Just (dir, dirs) -> PNext dir (formulaAfter dirs f)

formulaAtDown :: Int -> Formula a -> Formula a
formulaAtDown n f
  | n <= 1         = f
  | otherwise = formulaAtDown (n-1) (PNext Down f)

formulaAtUp :: Int -> Formula a -> Formula a
formulaAtUp n f
  | n <= 1         = f
  | otherwise = formulaAtDown (n-1) (PNext Up f)

negation :: Formula a -> Formula a
negation (Not f) = f
negation f = Not f

-- remove double negation
normalize :: Formula a -> Formula a
normalize f = case f of
  T                    -> f
  Atomic _             -> f
  Not (Not g)          -> normalize g
  Not (Always g)       -> Eventually . normalize . Not $ g
  Not (Historically g) -> Once . normalize . Not $ g
  Not g                -> Not (normalize g)
  Or g h               -> Or  (normalize g) (normalize h)
  And g h              -> And (normalize g) (normalize h)
  Xor g h              -> Xor (normalize g) (normalize h)
  Implies g h          -> Implies (normalize g) (normalize h)
  Iff g h              -> Iff (normalize g) (normalize h)
  PNext dir g          -> PNext dir (normalize g)
  PBack dir g          -> PBack dir (normalize g)
  XNext dir g          -> XNext dir (normalize g)
  XBack dir g          -> XBack dir (normalize g)
  HNext dir g          -> HNext dir (normalize g)
  HBack dir g          -> HBack dir (normalize g)
  Until dir g h        -> Until dir (normalize g) (normalize h)
  Since dir g h        -> Since dir (normalize g) (normalize h)
  HUntil dir g h       -> HUntil dir (normalize g) (normalize h)
  HSince dir g h       -> HSince dir (normalize g) (normalize h)
  WPNext dir g         -> WPNext dir (normalize g)
  WXNext dir g         -> WXNext dir (normalize g)
  WHNext dir g         -> WHNext dir (normalize g)
  Release dir g h      -> Release dir (normalize g) (normalize h)
  HRelease dir g h     -> HRelease dir (normalize g) (normalize h)
  Next g               -> Next (normalize g)
  WNext g              -> WNext (normalize g)
  Back g               -> Back (normalize g)
  WBack g              -> WBack (normalize g)
  Eventually g         -> Eventually (normalize g)
  Always g             -> Not . Eventually . normalize . Not $ g
  Once g               -> Once (normalize g)
  Historically g       -> Not . Historically . normalize . Not $ g
  GUntil g h           -> GUntil (normalize g) (normalize h)
  AuxBack dir g        -> AuxBack dir (normalize g)

-- to positive normal form
pnf :: Formula a -> Formula a
pnf f = case f of
  -- Positive operators
  T                  -> f
  Atomic _           -> f
  Or g h             -> Or  (pnf g) (pnf h)
  And g h            -> And (pnf g) (pnf h)
  Xor g h            -> Xor (pnf g) (pnf h)
  Implies g h        -> Implies (pnf g) (pnf h)
  Iff g h            -> Iff (pnf g) (pnf h)
  PNext dir g        -> PNext dir (pnf g)
  PBack dir g        -> PBack dir (pnf g)
  XNext dir g        -> XNext dir (pnf g)
  XBack dir g        -> XBack dir (pnf g)
  HNext dir g        -> HNext dir (pnf g)
  HBack dir g        -> HBack dir (pnf g)
  Until dir g h      -> Until dir (pnf g) (pnf h)
  Since dir g h      -> Since dir (pnf g) (pnf h)
  HUntil dir g h     -> HUntil dir (pnf g) (pnf h)
  HSince dir g h     -> HSince dir (pnf g) (pnf h)
  WPNext dir g       -> WPNext dir (pnf g)
  WXNext dir g       -> WXNext dir (pnf g)
  WHNext dir g       -> WHNext dir (pnf g)
  Release dir g h    -> Release dir (pnf g) (pnf h)
  HRelease dir g h   -> HRelease dir (pnf g) (pnf h)
  Next g             -> Next (pnf g)
  WNext g            -> WNext (pnf g)
  Back g             -> Back (pnf g)
  WBack g            -> WBack (pnf g)
  Eventually g       -> Eventually (pnf g)
  Always g           -> Always (pnf g)
  Once g             -> Once (pnf g)
  Historically g     -> Historically (pnf g)
  GUntil g h         -> GUntil (pnf g) (pnf h)
  AuxBack dir g      -> AuxBack dir (pnf g)
  -- Negated operators
  Not T                   -> f
  Not (Atomic _)          -> f
  Not (Not g)             -> pnf g
  Not (Or g h)            -> And (pnf $ Not g) (pnf $ Not h)
  Not (And g h)           -> Or (pnf $ Not g) (pnf $ Not h)
  Not (Xor g h)           -> Iff (pnf g) (pnf h)
  Not (Implies g h)       -> And (pnf g) (pnf $ Not h)
  Not (Iff g h)           -> Xor (pnf g) (pnf h)
  Not (PNext dir g)       -> WPNext dir (pnf $ Not g)
  Not (PBack _dir _g)     -> error "Past weak operators not supported yet." -- WPBack dir (pnf $ Not g)
  Not (XNext dir g)       -> WXNext dir (pnf $ Not g)
  Not (XBack _dir _g)     -> error "Past weak operators not supported yet." -- WXBack dir (pnf $ Not g)
  Not (HNext dir g)       -> WHNext dir (pnf $ Not g)
  Not (HBack _dir _g)     -> error "Hierarchical weak operators not supported yet." -- HBack dir (pnf $ Not g)
  Not (Until dir g h)     -> Release dir (pnf $ Not g) (pnf $ Not h)
  Not (Release dir g h)   -> Until dir (pnf $ Not g) (pnf $ Not h)
  Not (Since _dir _g _h)  -> error "Past weak operators not supported yet." -- PRelease dir (pnf $ Not g) (pnf $ Not h)
  Not (HUntil dir g h)    -> HRelease dir (pnf $ Not g) (pnf $ Not h)
  Not (HRelease dir g h)  -> HUntil dir (pnf $ Not g) (pnf $ Not h)
  Not (HSince _dir _g _h) -> error "Past weak operators not supported yet." -- HPRelease dir (pnf $ Not g) (pnf $ Not h)
  Not (WPNext dir g)      -> PNext dir (pnf $ Not g)
  Not (WXNext dir g)      -> XNext dir (pnf $ Not g)
  Not (WHNext dir g)      -> HNext dir (pnf $ Not g)
  Not (Next g)            -> WNext (pnf $ Not g)
  Not (WNext g)           -> Next (pnf $ Not g)
  Not (Back g)            -> WBack (pnf $ Not g)
  Not (WBack g)           -> Back (pnf $ Not g)
  Not (Eventually g)      -> Always (pnf $ Not g)
  Not (Always g)          -> Eventually (pnf $ Not g)
  Not (Once g)            -> Historically (pnf $ Not g)
  Not (Historically g)    -> Once (pnf $ Not g)
  Not (GUntil _g _h)      -> error "LTL release operator not supported yet."
  Not (AuxBack _dir _g)   -> error "Negated auxiliary operators cannot be normalized."

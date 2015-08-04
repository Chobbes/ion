{- |
Module: Ion
Description: Top-level Ion module
Copyright: (c) 2015 Chris Hodapp

Ion is a Haskell EDSL that is inspired by another EDSL,
<https://hackage.haskell.org/package/atom Atom>.  Ion aims to be a
re-implementation of Atom which, rather than generating C code directly (as
Atom does), interfaces with another very powerful, more general EDSL,
<http://ivorylang.org/ Ivory>.

To-do items:

   * I need to convert over the 'schedule' function in Scheduling.hs in Atom.
(This is partially done in 'flatten'.)
   * I can do a relative phase; what about a relative period? That is, a
period which is relative not to the base rate, but to the last rate that was
inherited.
   * Counterpart to 'cond' in Atom should compose as 'phase' and 'period' do.
(Is this necessary when I can just use the Ivory conditional?)
   * A combinator to explicitly disable a rule (also composing like 'cond')
might be nice too.
   * I need to either mandate that Ion names must be C identifiers, or make
a way to sanitize them into C identifiers.
   * Atom treats everything within a node as happening at the same time, and I
do not handle this yet, though I rather should.  This may be complicated - I
may either need to process the Ivory effect to look at variable references, or
perhaps add certain features to the monad.
   * Right now one can only pass variables to an Ion by way of a Ref or some
derivative, and those must then be dereferenced inside of an 'ivoryEff' call.
Is this okay?  Should we make this more flexible somehow?  (I feel like Atom
did it similarly, with V & E.)

-}
{-# LANGUAGE FlexibleInstances #-}

module Ion where

import           Control.Exception
import           Control.Monad
import           Data.Maybe ( mapMaybe )

import qualified Ivory.Language as IL
import qualified Ivory.Language.Monad as ILM

-- | The monad for expressing an Ion specification.
data Ion a = Ion { ionNodes :: [IonNode] -- ^ An accumulation of nodes; the
                   -- head is considered the 'current' node
                 , ionVal :: a
                 } deriving (Show)

instance Functor Ion where
  fmap f ion = ion { ionVal = f $ ionVal ion }

instance Applicative Ion where
  pure = return
  (<*>) = ap

instance Monad Ion where
  ion1 >>= fn = ion2 { ionNodes = ionNodes ion2 ++ ionNodes ion1 }
    where ion2 = fn $ ionVal ion1

  return a = Ion { ionNodes = [], ionVal = a }

-- | A node representing some context in the schedule, and the actions this
-- node includes.  'ionAction' (except for 'IvoryEff' and 'NoAction') applies
-- not just to the current node, but to any child nodes too.  In general,
-- if two actions conflict (e.g. two 'SetPhase' actions with absolute phase),
-- then the innermost one overrides the other.
data IonNode = IonNode { ionAction :: IonAction -- ^ What this node does
                       , ionSub :: [IonNode] -- ^ Child nodes
                       } deriving (Show)

-- | The type of Ivory action that an 'IonNode' can support. Note that this
-- purposely forbids breaking, returning, and allocating.
type IvoryAction = IL.Ivory IL.NoEffects ()

instance Show IvoryAction where
  show iv = "Ivory NoEffects () [" ++ show block ++ "]"
    where (_, block) = ILM.runIvory $ ILM.noReturn $ ILM.noBreak $ ILM.noAlloc iv

-- | An action/effect that a node can have.
data IonAction = IvoryEff IvoryAction -- ^ The Ivory effects that this
                 -- node should perform
               | SetPhase Phase -- ^ Setting phase
               | SetPeriod Int -- ^ Setting period
               | SetName String -- ^ Setting a name
               | NoAction -- ^ Do nothing
               deriving (Show)

-- | A phase - i.e. the count within a period (thus, an absolute phase must
-- range from @0@ up to @N-1@ for period @N@).
data Phase = Phase PhaseContext PhaseType Int deriving (Show)

data PhaseContext = Absolute -- ^ Phase is relative to the first tick within a
                    -- period
                  | Relative -- ^ Phase is relative to the last phase used
                  deriving (Show)

data PhaseType = Min -- ^ Minimum phase (i.e. at this phase, or any later point)
               | Exact -- ^ Exactly this phase
               deriving (Show)

defaultNode = IonNode { ionAction = NoAction
                      , ionSub = []
                      }

-- | Produce a somewhat more human-readable representation of an 'Ion'
prettyPrint :: IonNode -> IO ()
prettyPrint node = putStrLn $ unlines $ pretty node
  where sub s = join $ map pretty $ ionSub s
        pretty s = [ "IonNode {"
                   , " ionAction = " ++ (show $ ionAction s)
                   ] ++
                   (if null $ ionSub s
                    then []
                    else " ionSub =" : (map ("    " ++) $ sub s)) ++
                   ["}"]

-- | Given a function which transforms an 'IonNode', and a child 'Ion', return
-- the parent 'Ion' containing this node with that transformation applied.
makeSub :: (IonNode -> IonNode) -> Ion a -> Ion a
makeSub fn ion0 = ion0
                  { ionNodes = [(fn defaultNode) { ionSub = ionNodes ion0 }] }

-- | Given an 'IonAction' to apply, and a child 'Ion', return the parent 'Ion'
-- containing this node with that action.
makeSubFromAction :: IonAction -> Ion a -> Ion a
makeSubFromAction act = makeSub (\i -> i { ionAction = act })

-- | Specify a name of a sub-node, returning the parent.
ion :: String -- ^ Name
       -> Ion a -- ^ Sub-node
       -> Ion a
ion = makeSubFromAction . SetName

-- | Specify a phase for a sub-node, returning the parent. (The sub-node may
-- readily override this phase.)
phase :: Int -- ^ Phase
         -> Ion a -- ^ Sub-node
         -> Ion a
phase = makeSubFromAction . SetPhase . Phase Relative Min
-- FIXME: This needs to comprehend the different phase types.

-- | Specify a period for a sub-node, returning the parent. (The sub-node may
-- readily override this period.)
period :: Int -- ^ Period
          -> Ion a -- ^ Sub-node
          -> Ion a
period = makeSubFromAction . SetPeriod

-- | Turn an Ivory effect into an 'Ion'.
ivoryEff :: IvoryAction -> Ion ()
ivoryEff iv = Ion { ionNodes = [defaultNode { ionAction = IvoryEff iv }]
                  , ionVal = ()
                  }

-- | A scheduled action.  Phase and period here are absolute, and there are no
-- child nodes.
data Schedule = Schedule { schedName :: String
                         , schedPath :: [String]
                         , schedPhase :: Integer
                         , schedPeriod :: Integer
                         , schedAction :: [IvoryAction]
                         }
              deriving (Show)

defaultSchedule = Schedule { schedName = "root"
                           , schedPath = []
                           , schedPhase = 0
                           , schedPeriod = 1
                           , schedAction = []
                           }

-- | Walk a hierarchical 'IonNode' and turn it into a flat list of
-- scheduled actions, given a starting context (another 'Schedule')
flatten :: Schedule -- ^ Starting schedule (e.g. 'defaultSchedule')
           -> IonNode -- ^ Starting node
           -> [Schedule]
flatten ctxt node = newSched ++ (join $ map (flatten ctxtClean) $ ionSub node)
  where ctxt' = case ionAction node of
                 IvoryEff iv -> ctxt
                 SetPhase (Phase _ _ ph) ->
                   ctxt { schedPhase = fromIntegral ph }
                   -- FIXME: Handle real phase.
                 SetPeriod p -> ctxt { schedPeriod = fromIntegral p }
                 SetName name -> ctxt { schedName = name
                                      , schedPath = schedPath ctxt ++ [name]
                                      }
                 NoAction -> ctxt
                 a@_ -> error ("Unknown action type: " ++ show a)
        -- For the context that we pass forward, clear out the action; actions
        -- run only once:
        ctxtClean = ctxt' { schedAction = [] }
        -- Emit schedule nodes for any children that have Ivory effects:
        -- (We do this to combine all effects at once that are under the same
        -- parameters.)
        getIvory node = case ionAction node of IvoryEff iv -> Just iv
                                               _           -> Nothing
        ivoryActions = mapMaybe getIvory $ ionSub node
        newSched = if null ivoryActions
                   then [] -- If no actions, don't even emit a schedule item.
                   else [ctxt' {schedAction = ivoryActions, schedName = name}]
        -- Disambiguate the name
        name = schedName ctxt' ++ "_" ++ (show $ schedPhase ctxt') ++ "_" ++
               (show $ schedPeriod ctxt')
-- FIXME: Check for duplicate names?

data IonException = NodeUnboundException IonNode
    deriving (Show)

instance Exception IonException

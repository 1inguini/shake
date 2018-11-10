{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving, ConstraintKinds #-}
{-# LANGUAGE ExistentialQuantification, RankNTypes #-}
{-# LANGUAGE TypeFamilies, DeriveDataTypeable #-}

module Development.Shake.Internal.Core.Rules(
    Rules, runRules, getTargets, Target(..),
    RuleResult, addBuiltinRule, addBuiltinRuleEx,
    noLint, noIdentity,
    getShakeOptionsRules,
    getUserRuleInternal, getUserRuleOne, getUserRuleList, getUserRuleMaybe,
    addUserRule, documentTarget, alternatives, priority, versioned,
    action, withoutActions
    ) where

import Control.Applicative
import Data.Tuple.Extra
import Control.Exception
import Control.Monad.Extra
import Control.Monad.Fix
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader
import Development.Shake.Classes
import General.Binary
import General.Extra
import Data.Data
import Data.Function
import Data.List.Extra
import qualified Data.HashMap.Strict as Map
import qualified General.TypeMap as TMap
import Data.Maybe
import Data.IORef.Extra
import System.IO.Extra
import Data.Semigroup (Semigroup (..))
import Data.Monoid hiding ((<>))
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Binary.Builder as Bin
import Data.Binary.Put
import Data.Binary.Get
import General.ListBuilder

import Development.Shake.Internal.Core.Types
import Development.Shake.Internal.Core.Monad
import Development.Shake.Internal.Value
import Development.Shake.Internal.Options
import Development.Shake.Internal.Errors
import Prelude


---------------------------------------------------------------------
-- RULES

-- | Get the 'ShakeOptions' that were used.
getShakeOptionsRules :: Rules ShakeOptions
getShakeOptionsRules = Rules $ asks fst


-- | Internal variant, more flexible, but not such a nice API
--   Same args as getuserRuleMaybe, but returns (guaranteed version, items, error to throw if wrong number)
--   Fields are returned lazily, in particular ver can be looked up cheaper
getUserRuleInternal :: forall key a b . (ShakeValue key, Typeable a) => key -> (a -> Maybe String) -> (a -> Maybe b) -> Action (Maybe Ver, [(Int, b)], SomeException)
getUserRuleInternal key disp test = do
    Global{..} <- Action getRO
    let UserRuleVersioned versioned rules = fromMaybe mempty $ TMap.lookup globalUserRules
    let ver = if versioned then Nothing else Just $ Ver 0
    let items = head $ (map snd $ reverse $ groupSort $ f (Ver 0) Nothing rules) ++ [[]]
    let err = errorMultipleRulesMatch (typeOf key) (show key) (map snd3 items)
    return (ver, map (\(Ver v,_,x) -> (v,x)) items, err)
    where
        f :: Ver -> Maybe Double -> UserRule a -> [(Double,(Ver,Maybe String,b))]
        f v p (UserRule x) = [(fromMaybe 1 p, (v,disp x,x2)) | Just x2 <- [test x]]
        f v p (Unordered xs) = concatMap (f v p) xs
        f v p (Priority p2 x) = f v (Just $ fromMaybe p2 p) x
        f _ p (Versioned v x) = f v p x
        f v p (Alternative x) = take 1 $ f v p x


-- | Get the user rules that were added at a particular type which return 'Just' on a given function.
--   Return all equally applicable rules, paired with the version of the rule
--   (set by 'versioned'). Where rules are specified with 'alternatives' or 'priority'
--   the less-applicable rules will not be returned.
--
--   If you can only deal with zero/one results, call 'getUserRuleMaybe' or 'getUserRuleOne',
--   which raise informative errors.
getUserRuleList :: Typeable a => (a -> Maybe b) -> Action [(Int, b)]
getUserRuleList test = snd3 <$> getUserRuleInternal () (const Nothing) test


-- | A version of 'getUserRuleList' that fails if there is more than one result
--   Requires a @key@ for better error messages.
getUserRuleMaybe :: (ShakeValue key, Typeable a) => key -> (a -> Maybe String) -> (a -> Maybe b) -> Action (Maybe (Int, b))
getUserRuleMaybe key disp test = do
    (_, xs, err) <- getUserRuleInternal key disp test
    case xs of
        [] -> return Nothing
        [x] -> return $ Just x
        _ -> throwM err

-- | A version of 'getUserRuleList' that fails if there is not exactly one result
--   Requires a @key@ for better error messages.
getUserRuleOne :: (ShakeValue key, Typeable a) => key -> (a -> Maybe String) -> (a -> Maybe b) -> Action (Int, b)
getUserRuleOne key disp test = do
    (_, xs, err) <- getUserRuleInternal key disp test
    case xs of
        [x] -> return x
        _ -> throwM err


-- | Define a set of rules. Rules can be created with calls to functions such as 'Development.Shake.%>' or 'action'.
--   Rules are combined with either the 'Monoid' instance, or (more commonly) the 'Monad' instance and @do@ notation.
--   To define your own custom types of rule, see "Development.Shake.Rule".
newtype Rules a = Rules (ReaderT (ShakeOptions, IORef SRules) IO a) -- All IO must be associative/commutative (e.g. creating IORef/MVars)
    deriving (Functor, Applicative, Monad, MonadIO, MonadFix)

newRules :: SRules -> Rules ()
newRules x = Rules $ liftIO . flip modifyIORef' (<> x) =<< asks snd

modifyRules :: (SRules -> SRules) -> Rules a -> Rules a
modifyRules f (Rules r) = Rules $ do
    (opts, refOld) <- ask
    liftIO $ do
        refNew <- newIORef mempty
        res <- runReaderT r (opts, refNew)
        rules <- readIORef refNew
        modifyIORef' refOld (<> f rules)
        return res

runRules :: ShakeOptions -> Rules () -> IO ([(Stack, Action ())], Map.HashMap TypeRep BuiltinRule, TMap.Map UserRuleVersioned, [Target])
runRules opts (Rules r) = do
    ref <- newIORef mempty
    runReaderT r (opts, ref)
    SRules{..} <- readIORef ref
    return (runListBuilder actions, builtinRules, userRules, runListBuilder targets)

-- | Get all the targets explicitly registered in the given rules. The names in
-- 'phony' and '~>' as well as the file patterns in '%>', '|%>' and '&%>' are
-- registered as targets.
--
-- One application for retrieving the targets from the rules is for implementing
-- a shell autocomplete feature. To implement autocompletion most shells require
-- the program to output the list of arguments it supports. In this case we want
-- to output "someTarget" and "someFile" when the program is invoked with the
-- "autocomplete" command.
--
-- @
-- main = do
--   let rules = do
--         phony "someTarget" $ pure ()
--         "someFile" %> \\_ -> pure ()
--   shakeArgsWith shakeOptions [] $ \\_flags targets ->
--     case targets of
--       "autocomplete" : _args -> do
--          targets <- getTargets shakeOptions rules
--          forM_ targets $ \\t ->
--            putStrLn $ target t ++
--              maybe "" (\\doc -> ":" ++ doc) (documentation t)
--          pure Nothing
--       target : _args -> pure $ Just $ want [ target ] >> rules
-- @
getTargets :: ShakeOptions -> Rules () -> IO [Target]
getTargets opts rs = do
  (_actions, _ruleinfo, _userRules, targets) <- runRules opts rs
  return targets

data Target = Target
    {target :: !String
    ,documentation :: !(Maybe String)
    } deriving (Eq,Ord,Show,Read,Data,Typeable)

data SRules = SRules
    {actions :: !(ListBuilder (Stack, Action ()))
    ,builtinRules :: !(Map.HashMap TypeRep{-k-} BuiltinRule)
    ,userRules :: !(TMap.Map UserRuleVersioned)
    ,targets :: !(ListBuilder Target)
    }

instance Semigroup SRules where
    (SRules x1 x2 x3 x4) <> (SRules y1 y2 y3 y4) = SRules (mappend x1 y1) (Map.unionWithKey f x2 y2) (TMap.unionWith (<>) x3 y3) (mappend x4 y4)
        where f k a b = throwImpure $ errorRuleDefinedMultipleTimes k [builtinLocation a, builtinLocation b]

instance Monoid SRules where
    mempty = SRules mempty Map.empty TMap.empty mempty
    mappend = (<>)

instance Semigroup a => Semigroup (Rules a) where
    (<>) = liftA2 (<>)

instance (Semigroup a, Monoid a) => Monoid (Rules a) where
    mempty = return mempty
    mappend = (<>)


-- | Add a user rule. In general these should be specialised to the type expected by a builtin rule.
--   The user rules can be retrieved by 'getUserRuleList'.
addUserRule :: Typeable a => a -> Rules ()
addUserRule r = newRules mempty{userRules = TMap.singleton $ UserRuleVersioned False $ UserRule r}

-- | Register a 'Target' with some optional documentation.
--
-- The registered targets in a @Rules@ can be retrieved using 'getTargets'.
documentTarget
    :: String -- ^ Target name or file pattern
    -> Maybe String -- ^ Optional documentation that describes this target
    -> Rules ()
documentTarget t mbDoc = newRules mempty{targets = newListBuilder $ Target t mbDoc}

-- | A suitable 'BuiltinLint' that always succeeds.
noLint :: BuiltinLint key value
noLint _ _ = return Nothing

-- | A suitable 'BuiltinIdentity' that always fails with a runtime error, incompatible with 'shakeShare'.
--   Use this function if you don't care about 'shakeShare', or if your rule provides a dependency that can
--   never be cached (in which case you should also call 'Development.Shake.historyDisable').
noIdentity :: Typeable key => BuiltinIdentity key value
noIdentity k _ = throwImpure $ errorStructured
    "Key type does not support BuiltinIdentity, so does not work with 'shakeShare'"
    [("Key type", Just $ show (typeOf k))] []


-- | The type mapping between the @key@ or a rule and the resulting @value@.
--   See 'addBuiltinRule' and 'apply'.
type family RuleResult key -- = value

-- | Define a builtin rule, passing the functions to run in the right circumstances.
--   The @key@ and @value@ types will be what is used by 'Development.Shake.apply'.
--   As a start, you can use 'noLint' and 'noIdentity' as the first two functions,
--   but are required to supply a suitable 'BuiltinRun'.
--
--   Raises an error if any other rule exists at this type.
addBuiltinRule
    :: (RuleResult key ~ value, ShakeValue key, Typeable value, NFData value, Show value, Partial)
    => BuiltinLint key value -> BuiltinIdentity key value -> BuiltinRun key value -> Rules ()
addBuiltinRule = withFrozenCallStack $ addBuiltinRuleInternal $ BinaryOp
    (putEx . Bin.toLazyByteString . execPut . put)
    (runGet get . LBS.fromChunks . return)

addBuiltinRuleEx
    :: (RuleResult key ~ value, ShakeValue key, BinaryEx key, Typeable value, NFData value, Show value, Partial)
    => BuiltinLint key value -> BuiltinIdentity key value -> BuiltinRun key value -> Rules ()
addBuiltinRuleEx = addBuiltinRuleInternal $ BinaryOp putEx getEx


-- | Unexpected version of 'addBuiltinRule', which also lets me set the 'BinaryOp'.
addBuiltinRuleInternal
    :: (RuleResult key ~ value, ShakeValue key, Typeable value, NFData value, Show value, Partial)
    => BinaryOp key -> BuiltinLint key value -> BuiltinIdentity key value -> BuiltinRun key value -> Rules ()
addBuiltinRuleInternal binary lint check (run :: BuiltinRun key value) = do
    let k = Proxy :: Proxy key
    let lint_ k v = lint (fromKey k) (fromValue v)
    let check_ k v = check (fromKey k) (fromValue v)
    let run_ k v b = fmap newValue <$> run (fromKey k) v b
    let binary_ = BinaryOp (putOp binary . fromKey) (newKey . getOp binary)
    newRules mempty{builtinRules = Map.singleton (typeRep k) $ BuiltinRule lint_ check_ run_ binary_ (Ver 0) callStackTop}


-- | Change the priority of a given set of rules, where higher priorities take precedence.
--   All matching rules at a given priority must be disjoint, or an error is raised.
--   All builtin Shake rules have priority between 0 and 1.
--   Excessive use of 'priority' is discouraged. As an example:
--
-- @
-- 'priority' 4 $ \"hello.*\" %> \\out -> 'writeFile'' out \"hello.*\"
-- 'priority' 8 $ \"*.txt\" %> \\out -> 'writeFile'' out \"*.txt\"
-- @
--
--   In this example @hello.txt@ will match the second rule, instead of raising an error about ambiguity.
--
--   The 'priority' function obeys the invariants:
--
-- @
-- 'priority' p1 ('priority' p2 r1) === 'priority' p1 r1
-- 'priority' p1 (r1 >> r2) === 'priority' p1 r1 >> 'priority' p1 r2
-- @
priority :: Double -> Rules a -> Rules a
priority d = modifyRules $ \s -> s{userRules = TMap.map (\(UserRuleVersioned b x) -> UserRuleVersioned b $ Priority d x) $ userRules s}


-- | Indicate that the nested rules have a given version. If you change the semantics of the rule then updating (or adding)
--   a version will cause the rule to rebuild in some circumstances.
--
-- @
-- 'versioned' 1 $ \"hello.*\" %> \\out ->
--     'writeFile'' out \"Writes v1 now\" -- previously wrote out v0
-- @
--
--   You should only use 'versioned' to track changes in the build source, for standard runtime dependencies you should use
--   other mechanisms, e.g. 'Development.Shake.addOracle'.
versioned :: Int -> Rules a -> Rules a
versioned v = modifyRules $ \s -> s
    {userRules = TMap.map (\(UserRuleVersioned b x) -> UserRuleVersioned (b || v /= 0) $ Versioned (Ver v) x) $ userRules s
    ,builtinRules = Map.map (\b -> b{builtinVersion = Ver v}) $ builtinRules s
    }


-- | Change the matching behaviour of rules so rules do not have to be disjoint, but are instead matched
--   in order. Only recommended for small blocks containing a handful of rules.
--
-- @
-- 'alternatives' $ do
--     \"hello.*\" %> \\out -> 'writeFile'' out \"hello.*\"
--     \"*.txt\" %> \\out -> 'writeFile'' out \"*.txt\"
-- @
--
--   In this example @hello.txt@ will match the first rule, instead of raising an error about ambiguity.
--   Inside 'alternatives' the 'priority' of each rule is not used to determine which rule matches,
--   but the resulting match uses that priority compared to the rules outside the 'alternatives' block.
alternatives :: Rules a -> Rules a
alternatives = modifyRules $ \r -> r{userRules = TMap.map (\(UserRuleVersioned b x) -> UserRuleVersioned b $ Alternative x) $ userRules r}


-- | Run an action, usually used for specifying top-level requirements.
--
-- @
-- main = 'Development.Shake.shake' 'shakeOptions' $ do
--    'action' $ do
--        b <- 'Development.Shake.doesFileExist' \"file.src\"
--        when b $ 'Development.Shake.need' [\"file.out\"]
-- @
--
--   This 'action' builds @file.out@, but only if @file.src@ exists. The 'action'
--   will be run in every build execution (unless 'withoutActions' is used), so only cheap
--   operations should be performed. On the flip side, consulting system information
--   (e.g. environment variables) can be done directly as the information will not be cached.
--   All calls to 'action' may be run in parallel, in any order.
--
--   For the standard requirement of only 'Development.Shake.need'ing a fixed list of files in the 'action',
--   see 'Development.Shake.want'.
action :: Partial => Action a -> Rules ()
action act = newRules mempty{actions=newListBuilder (addCallStack callStackFull emptyStack, void act)}


-- | Remove all actions specified in a set of rules, usually used for implementing
--   command line specification of what to build.
withoutActions :: Rules a -> Rules a
withoutActions = modifyRules $ \x -> x{actions=mempty}

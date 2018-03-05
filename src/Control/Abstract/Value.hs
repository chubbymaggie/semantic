{-# LANGUAGE MultiParamTypeClasses, UndecidableInstances #-}
module Control.Abstract.Value where

import Control.Abstract.Addressable
import Control.Abstract.Analysis
import Control.Abstract.Evaluator
import Control.Monad.Effect.Fresh
import Data.Abstract.Address
import Data.Abstract.Environment
import Data.Abstract.FreeVariables
import Data.Abstract.Value as Value
import Data.Abstract.Type as Type
import Prologue
import Prelude hiding (fail)

-- | A 'Monad' abstracting the evaluation of (and under) binding constructs (functions, methods, etc).
--
--   This allows us to abstract the choice of whether to evaluate under binders for different value types.
class (MonadEvaluator t v m) => MonadValue t v m where
  -- | Construct an abstract unit value.
  unit :: m v

  -- | Construct an abstract integral value.
  integer :: Prelude.Integer -> m v

  -- | Construct an abstract boolean value.
  boolean :: Bool -> m v

  -- | Construct an abstract string value.
  string :: ByteString -> m v

  -- | Eliminate boolean values. TODO: s/boolean/truthy
  ifthenelse :: v -> m v -> m v -> m v

  -- | Evaluate an abstraction (a binder like a lambda or method definition).
  abstract :: [Name] -> Subterm t (m v) -> m v
  -- | Evaluate an application (like a function call).
  apply :: v -> [Subterm t (m v)] -> m v

-- | Construct a 'Value' wrapping the value arguments (if any).
instance ( FreeVariables t
         , MonadAddressable location (Value location t) m
         , MonadAnalysis t (Value location t) m
         , MonadEvaluator t (Value location t) m
         , Recursive t
         , Semigroup (Cell location (Value location t))
         )
         => MonadValue t (Value location t) m where

  unit    = pure $ inj Value.Unit
  integer = pure . inj . Integer
  boolean = pure . inj . Boolean
  string  = pure . inj . Value.String

  ifthenelse cond if' else'
    | Just (Boolean b) <- prj cond = if b then if' else else'
    | otherwise = fail "not defined for non-boolean conditions"

  abstract names (Subterm body _) = inj . Closure names body <$> askLocalEnv

  apply op params = do
    Closure names body env <- maybe (fail "expected a closure") pure (prj op)
    bindings <- foldr (\ (name, param) rest -> do
      v <- subtermValue param
      a <- alloc name
      assign a v
      envInsert name a <$> rest) (pure env) (zip names params)
    localEnv (mappend bindings) (evaluateTerm body)

-- | Discard the value arguments (if any), constructing a 'Type.Type' instead.
instance (Alternative m, MonadEvaluator t Type m, MonadFresh m) => MonadValue t Type m where
  abstract names (Subterm _ body) = do
    (env, tvars) <- foldr (\ name rest -> do
      a <- alloc name
      tvar <- Var <$> fresh
      assign a tvar
      (env, tvars) <- rest
      pure (envInsert name a env, tvar : tvars)) (pure mempty) names
    ret <- localEnv (mappend env) body
    pure (Product tvars :-> ret)

  unit      = pure Type.Unit
  integer _ = pure Int
  boolean _ = pure Bool
  string _  = pure Type.String

  ifthenelse cond if' else' = unify cond Bool *> (if' <|> else')

  apply op params = do
    tvar <- fresh
    paramTypes <- traverse subtermValue params
    _ :-> ret <- op `unify` (Product paramTypes :-> Var tvar)
    pure ret
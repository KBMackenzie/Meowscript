{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

module Meowscript.Core.Primitives
(
) where

import Meowscript.Core.AST
import Data.IORef
import Meowscript.Core.Environment
import Meowscript.Core.Pretty
import qualified Data.Text as Text
import qualified Data.Map as Map
import Control.Monad.Reader (asks, ask, liftIO, local)
import Control.Monad.Except (throwError)
import Data.Functor ((<&>))

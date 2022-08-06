{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ViewPatterns          #-}
{-# OPTIONS_GHC -Wall              #-}

module Purge where

import DB
import Hasql.Connection (acquire)
import Hasql.Session
import Rel8
import Signals (forbidPaths, forbidSites)
import qualified Data.Text as T

main :: IO ()
main = do
  Right conn <- acquire connectionSettings
  Right n <- flip run conn $ statement () $ delete $ Delete
    { from = documentSchema
    , using = pure ()
    , deleteWhere = \_ d -> do
        let paths =
              foldr1 (||.) $ do
                z <- forbidPaths
                pure $ like (lit $ T.pack $ "%" <> z <> "%") $ d_uri d
            sites =
              foldr1 (||.) $ do
                z <- forbidSites
                pure $ like (lit $ T.pack $ "%" <> z <> "/%") $ d_uri d
        paths ||. sites
    , returning = NumberOfRowsAffected
    }
  putStrLn $ "deleted " <> show n <> " rows"
  pure ()


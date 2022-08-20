module Tools.Purge where

import           Control.Monad (void, when)
import           DB
import           Data.Maybe (fromMaybe)
import qualified Data.Text as T
import           Data.Text.Encoding (decodeUtf8)
import           Marlo.Manager (marloManager)
import           Rel8
import           Signals (forbidPaths, forbidSites, isSpiritualPolution)
import           Types
import           Utils (runRanker, unsafeURI, withDocuments)


main :: IO ()
main = do
  Right conn <- connect
  Right n <- doDelete conn $ Delete
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
  putStrLn $ "deleted " <> show n <> " rows by uri"

  withDocuments conn (\d -> d_state d ==. lit Explored) $ \doc -> do
    is_polution <-
      runRanker
        (Env (unsafeURI $ T.unpack $ d_uri doc) marloManager conn)
        (decodeUtf8 $ prd_data $ d_raw doc)
        isSpiritualPolution
    when (fromMaybe False is_polution) $ do
      putStrLn $ T.unpack $ "poluted: " <> d_uri doc
      void $ doUpdate conn $ Update
        { target = documentSchema
        , from = pure ()
        , set = \_ d -> d { d_state = lit Unacceptable }
        , updateWhere = \_ d -> d_docId d ==. lit (d_docId doc)
        , returning = pure ()
        }


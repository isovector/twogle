module Spider where

import           Control.Exception.Base
import           Control.Monad (forever, void)
import           DB
import           Data.Bool (bool)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import           Data.Functor.Contravariant ((>$<))
import           Data.Int (Int32, Int16)
import           Data.Maybe (isJust)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Encoding (decodeUtf8)
import           Data.Traversable (for)
import           Domains (getDomain)
import           Network.HTTP (lookupHeader, HeaderName (HdrSetCookie))
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client.TLS as HTTP
import           Network.HTTP.Types (hContentType)
import           Network.URI (parseURI, URI)
import qualified Rel8 as R8 hiding (filter, bool)
import           Rel8 hiding (filter, bool, index)
import           Rel8.Arrays (arrayInc, arrayZipWithLeast)
import           Rel8.Headers (headersToHeaders)
import           Signals
import qualified Types
import           Types hiding (d_headers)
import           Utils (runRanker, unsafeURI, random)
import Data.Foldable (for_)


markExplored :: DocumentState -> Document Identity -> Update ()
markExplored ds d = Update
  { target = documentSchema
  , from = pure ()
  , set = \ _ dis -> dis { d_state = lit ds }
  , updateWhere = \ _ dis -> d_docId dis ==. lit (d_docId d)
  , returning = pure ()
  }


docIdFor :: URI -> Query (Document Expr)
docIdFor uri = do
  dis <- each documentSchema
  where_ $ d_uri dis ==. lit (T.pack $ show uri)
  pure dis



getDocId :: Connection -> Int32 -> [Maybe Int16] -> URI -> IO (Document Identity)
getDocId conn depth dist uri = do
    Right dids <- doSelect conn $ docIdFor uri
    case dids of
      [did] -> pure did
      [] -> do
        -- putStrLn $ "discovering " <> show uri
        Right dids' <- doInsert conn $ discover depth dist uri
        pure $ head dids'
      _ -> error $ "invalid database state: " <> show dids


discover :: Int32 -> [Maybe Int16] -> URI -> Insert [Document Identity]
discover depth dist uri = Insert
  { into = documentSchema
  , rows = do
      docid <- nextDocId
      pure $ (lit emptyDoc)
        { d_docId = docid
        , d_uri = lit $ T.pack $ show uri
        , d_state = lit Discovered
        , d_distance = arrayInc $ lit dist
        , d_depth = lit $ depth + 1
        }
  , onConflict = DoUpdate Upsert
      { index = d_uri
      , set = \new old -> old
          { d_depth = leastExpr (d_depth old) (d_depth new)
          , d_distance = arrayZipWithLeast (d_distance old) (d_distance new)
          }
      , updateWhere = \new old -> d_uri new ==. d_uri old
      }
  , returning = Projection id
  }


addEdge :: DocId -> Link DocId -> Insert [EdgeId]
addEdge src (Link anchor dst) = Insert
  { into = edgesSchema
  , rows = do
      eid <- nextEdgeId
      pure $ Edges eid (lit src) (lit dst) $ lit anchor
  , onConflict = DoNothing
  , returning = Projection e_edgeId
  }


buildEdges :: Connection -> Document Identity -> [Link URI] -> IO [EdgeId]
buildEdges conn disc ls = do
  ldocs' <- (traverse . traverse) (getDocId conn (d_depth disc) (d_distance disc)) ls
  let ldocs = filter ((/= d_docId disc) . l_uri) $ fmap (fmap d_docId) ldocs'

  for ldocs $ \l -> do
    Right [eid] <- doInsert conn $ addEdge (d_docId disc) l
    pure eid


spiderMain :: Maybe Text -> IO ()
spiderMain mexclude = do
  Right conn <- connect
  z <- doInsert conn rootNodes
  print z
  forever $ do
    Right [disc] <- doSelect conn $
      limit 1 $ orderBy ((d_depth >$< asc) <> random) $ do
        d <- each documentSchema
        where_ $ d_state d ==. lit Discovered
        for_ mexclude $ \exc ->
          where_ $ not_ $ like (lit exc) (d_uri d)
        pure d

    let url = d_uri disc
    case parseURI $ T.unpack url of
      Nothing -> error $ "died on bad URI: " <> show url
      Just uri -> do
        case isAcceptableLink uri of
          True -> do
            putStrLn $ "fetching " <> T.unpack url
            catch
              (do
                down <- fmap (sequenceDownload "text/html") $ downloadBody $ T.unpack url
                index conn (d_depth disc) (d_distance disc) uri down
              )
              (\SomeException{} -> do
                putStrLn $ "errored on " <> show (d_docId disc)
                void $ doUpdate conn $ markExplored Errored disc
              )
          False -> do
            putStrLn $ "ignoring " <> T.unpack url
            void $ doUpdate conn $ markExplored Pruned disc


index :: Connection -> Int32 -> [Maybe Int16] -> URI -> Download Identity ByteString -> IO ()
index conn depth dist uri down = do
  disc <- getDocId conn depth dist uri
  mgr <- HTTP.getGlobalManager
  case (d_mime down == "text/html" && isAcceptableLink uri) of
    True -> do
      let env = Env uri mgr conn
      Just (ls, t) <- runRanker env (decodeUtf8 $ d_body down) $ (,) <$> links <*> title
      void $ buildEdges conn disc ls

      let raw =
            PageRawData
              { prd_data = d_body down
              , prd_headers = fmap headersToHeaders $ Types.d_headers down
              }
      Right _ <- doUpdate conn $ Update
        { target = documentSchema
        , from = pure ()
        , set = \ _ dis -> dis
            { d_state = lit Explored
            , d_title = lit t
            , d_raw = lit raw
            }
        , updateWhere = \ _ dis -> d_docId dis ==. lit (d_docId disc)
        , returning = pure ()
        }
      indexCore conn env $ disc
        { d_state = Explored
        , d_title = t
        , d_raw = raw
        }
    False -> do
      void $ doUpdate conn $ markExplored Pruned disc


indexFromDB :: Connection -> Document Identity -> IO ()
indexFromDB conn disc = do
  let uri = unsafeURI $ T.unpack $ d_uri disc
  mgr <- HTTP.getGlobalManager
  case (isAcceptableLink uri) of
    True -> indexCore conn (Env uri mgr conn) disc
    False -> do
      void $ doUpdate conn $ markExplored Pruned disc


indexCore :: Connection -> Env -> Document Identity -> IO ()
indexCore conn env disc = do
  let uri = unsafeURI $ T.unpack $ d_uri disc
  dom_id <- getDomain conn uri
  Just (pc, has_ads, stats') <-
    runRanker env (decodeUtf8 $ prd_data $ d_raw disc) $
      (,,)
        <$> rankContent
        <*> hasGoogleAds
        <*> rankStats
  let stats = stats' { ps_cookies = isJust $ lookupHeader HdrSetCookie $ prd_headers $ d_raw disc }
  -- TODO(sandy): bug??? headers aren't being set
  Right () <-  doUpdate conn $ Update
    { target = documentSchema
    , from = pure ()
    , set = \ _ dis -> dis
        { d_domain = lit $ Just dom_id
        , d_page = lit pc
        , d_state    = lit $ bool Explored Unacceptable has_ads
        , d_stats    = lit stats
        }
    , updateWhere = \ _ dis -> d_docId dis ==. lit (d_docId disc)
    , returning = pure ()
    }
  pure ()


mimeToContentType :: ByteString -> ByteString
mimeToContentType = BS.takeWhile (/= ';')


downloadBody :: String -> IO (Download Maybe ByteString)
downloadBody url = do
  manager <- HTTP.getGlobalManager
  resp <- flip HTTP.httpLbs manager =<< HTTP.parseRequest url
  let mime = fmap mimeToContentType
            $ lookup hContentType
            $ HTTP.responseHeaders resp
  pure
    $ Download mime (HTTP.responseHeaders resp)
    $ BSL.toStrict $ HTTP.responseBody resp


debugRankerInDb :: Text -> Ranker a -> IO (Text, Maybe a)
debugRankerInDb uri r = do
  Right conn <- connect
  mgr <- HTTP.getGlobalManager
  Right [d] <-
    doSelect conn $ limit 1 $ do
      d <- each documentSchema
      where_ $ (like (lit $ "%" <> uri <> "%") $ d_uri d) &&. d_state d ==. lit Explored
      pure d
  let env = Env (unsafeURI $ T.unpack $ d_uri d) mgr conn
  fmap (d_uri d, ) $
    runRanker env (decodeUtf8 $ prd_data $ d_raw d) r


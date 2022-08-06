{-# OPTIONS_GHC -Wno-missing-signatures #-}

module Utils where

import           Control.Applicative ((<|>))
import           Control.Arrow (first)
import           Control.Monad.Reader
import           Data.Functor.Contravariant ((>$))
import           Data.Maybe (fromJust)
import           Data.Set (Set)
import qualified Data.Set as S
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time (getCurrentTime, NominalDiffTime)
import           Data.Time.Clock (diffUTCTime)
import           Network.URI
import           Rel8 (limit, offset, Order, nullaryFunction, asc)
import           Text.HTML.Scalpel
import           Text.Printf (printf)
import           Types


paginate size page q =
  limit size $
    offset (page * size) q


runRanker :: Env -> Text -> Ranker a -> IO (Maybe a)
runRanker e t = flip runReaderT e . scrapeStringLikeT t


countOf :: Selector -> Ranker Int
countOf sel = fmap length $ chroots sel $ pure ()


tagClass :: String -> String -> Selector
tagClass a b = TagString a @: [hasClass b]

tagId :: String -> String -> Selector
tagId a b = TagString a @: ["id" @= b]


classOf :: String -> Selector
classOf c = AnyTag @: [hasClass c]


unsafeURI :: String -> URI
unsafeURI = fromJust . parseURI


currentURI :: Ranker URI
currentURI = asks e_uri


withClass :: Selector -> (Text -> Bool) -> Ranker ()
withClass s f = do
  cls <- T.words <$> attr "class" s
  guard $ any f cls


has :: Ranker a -> Ranker Bool
has r = True <$ r <|> pure False


posKeywordsToInv :: [(Int, Text)] -> Set Text
posKeywordsToInv = S.fromList . fmap snd

timeItT :: IO a -> IO (NominalDiffTime, a)
timeItT ioa = do
    t1 <- getCurrentTime
    a <- ioa
    t2 <- getCurrentTime
    return (diffUTCTime t2 t1, a)

timing :: String -> IO a -> IO a
timing name ioa = do
    (t, a) <- fmap (first $ realToFrac @_ @Double) $ timeItT ioa
    liftIO $ printf (name ++ ": %6.4fs\n") t
    pure a

random :: Order a
random = nullaryFunction @Double "RANDOM" >$ asc

insertAt :: Int -> Int -> a -> [Maybe a]
insertAt (subtract 1 -> sz) ix a = replicate ix Nothing <> (Just a : replicate (sz - ix) Nothing)



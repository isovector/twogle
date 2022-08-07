{-# LANGUAGE LambdaCase #-}

module AppMain where

import           Data.Text (Text)
import           Options.Applicative
import qualified Search
import qualified Spider
import qualified Tools.BackfillDistance
import qualified Tools.BackfillPopularity
import qualified Tools.Purge
import qualified Tools.Reindex
import qualified Tools.ImportPopularity


data Command
  = SearchC
  | SpiderC (Maybe Text)
  | PurgeC
  | ReindexC
  | BackfillDistanceC
  | ImportPopularityC FilePath
  | BackfillPopularityC
  deriving (Eq, Ord, Show)


sub :: Parser Command
sub = subparser $ mconcat
  [ command "search" $ info (pure SearchC) $ mconcat
      [ progDesc "Start the search server"
      ]
  , command "spider" $ info (helper <*> parseSpider) $ mconcat
      [ progDesc "Start the spider"
      ]
  , command "purge" $ info (pure PurgeC) $ mconcat
      [ progDesc "Prune webpages that are now excluded by filter rules"
      ]
  , command "reindex" $ info (pure ReindexC) $ mconcat
      [ progDesc "Reindex every explored site"
      ]
  , command "backfill-distance" $ info (pure BackfillDistanceC) $ mconcat
      [ progDesc "Rerun the root-distance algorithm"
      ]
  , command "import-popularity" $ info (helper <*> parseImportPopularity) $ mconcat
      [ progDesc "Import website popularity from a statvoo CSV"
      ]
  , command "backfill-popularity" $ info (pure BackfillPopularityC) $ mconcat
      [ progDesc "Backfill website popularity from the alexa api"
      ]
  ]


parseSpider :: Parser Command
parseSpider =
  SpiderC
    <$> optional (strOption $ mconcat
          [ long "exclude"
          , help "A sql LIKE pattern to exclude uris from being indexed"
          ])


parseImportPopularity :: Parser Command
parseImportPopularity =
  ImportPopularityC
    <$> (argument str $ mconcat
          [ help "Path to the unzipped https://statvoo.com/dl/top-1million-sites.csv.zip"
          , metavar "CSV"
          ])


commandParser :: ParserInfo Command
commandParser =
  info (helper <*> versionOption <*> sub) $ mconcat
    [ fullDesc
    , header "marlo - search, for humans"
    ]


versionOption :: Parser (a -> a)
versionOption = infoOption "0.0" $ long "version" <> help "Show version"


main :: IO ()
main = do
  execParser commandParser >>= \case
     SearchC               -> Search.main
     SpiderC exc           -> Spider.spiderMain exc
     PurgeC                -> Tools.Purge.main
     ReindexC              -> Tools.Reindex.main
     BackfillDistanceC     -> Tools.BackfillDistance.main
     ImportPopularityC csv -> Tools.ImportPopularity.main csv
     BackfillPopularityC   -> Tools.BackfillPopularity.main


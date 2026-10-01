module Hilal.Migrate (migrate) where

import Data.FileEmbed (embedFile)
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as Direct
import Database.SQLite.Simple (Connection, connectionHandle)

migrate :: Connection -> IO ()
migrate conn =
  Direct.exec (connectionHandle conn) (TE.decodeUtf8 $(embedFile "schema.sql"))
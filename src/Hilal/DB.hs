module Hilal.DB (openDb, withDb) where

import Control.Exception ( bracket )
import qualified Database.SQLite3 as Direct
import Database.SQLite.Simple
    ( Connection(connectionHandle), close, open )

openDb :: FilePath -> IO Connection
openDb path = do
  conn <- open path
  let run = Direct.exec (connectionHandle conn)
  run "PRAGMA foreign_keys = ON" -- off by default in SQLite
  run "PRAGMA journal_mode = WAL" -- readers do NOT block writers
  run "PRAGMA busy_timeout = 5000" -- wait for 5s when locked
  return conn

withDb :: FilePath -> (Connection -> IO a) -> IO a
withDb path = bracket (openDb path) close
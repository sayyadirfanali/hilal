module Hilal.Azan
  ( Recording (..)
  , recordingName
  , findRecording
  , mosqueRecordings
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)
import System.Directory (doesFileExist)

import Hilal.Types (MosqueId (..))

-- A mosque's own Azan recordings. Only the superadmin adds them, as files copied into a folder
-- on the server: "12.ogg" for mosque 12's Azan, "12-fajr.ogg" for its Fajr Azan.
-- .mp3 and .m4a work too, so a recording sent from a phone can be used as it is.
data Recording = Azan | FajrAzan
  deriving (Show, Eq, Enum, Bounded)

-- As it appears in addresses and in the timings JSON.
recordingName :: Recording -> Text
recordingName r = case r of
  Azan     -> "azan"
  FajrAzan -> "azan-fajr"

-- The file for a mosque's recording, and its content type, if the superadmin has added one.
findRecording :: FilePath -> MosqueId -> Recording -> IO (Maybe (FilePath, Text))
findRecording dir (MosqueId n) r = firstExisting (map candidate formats)
  where
    base = dir <> "/" <> show n <> suffix
    suffix = case r of
      Azan     -> ""
      FajrAzan -> "-fajr"
    formats = [("ogg", "audio/ogg"), ("mp3", "audio/mpeg"), ("m4a", "audio/mp4")]
    candidate (ext, contentType) = (base <> "." <> ext, contentType)
    firstExisting [] = return Nothing
    firstExisting ((path, contentType) : rest) = do
      exists <- doesFileExist path
      if exists then return (Just (path, contentType)) else firstExisting rest

-- Which recordings a mosque has.
mosqueRecordings :: FilePath -> MosqueId -> IO [Recording]
mosqueRecordings dir mid = do
  found <- mapM (\r -> (\f -> (r, f)) <$> findRecording dir mid r) [minBound .. maxBound]
  return (map fst (filter (isJust . snd) found))

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
-- Mosque 0's, which no real mosque can be, are Hilal's default, for mosques without their own.
data Recording = Azan | FajrAzan
  deriving (Show, Eq, Enum, Bounded)

-- As it appears in addresses and in the timings JSON.
recordingName :: Recording -> Text
recordingName r = case r of
  Azan     -> "azan"
  FajrAzan -> "azan-fajr"

-- The file to play for a mosque's recording, and its content type: the mosque's own,
-- else the default; for Fajr, a Fajr Azan before a normal one, the mosque's before the default's.
-- Looked up on every request, so a newly added recording takes over at once.
findRecording :: FilePath -> MosqueId -> Recording -> IO (Maybe (FilePath, Text))
findRecording dir (MosqueId n) r = firstExisting (concatMap candidates (choices r))
  where
    choices Azan     = [(n, Azan), (0, Azan)]
    choices FajrAzan = [(n, FajrAzan), (n, Azan), (0, FajrAzan), (0, Azan)]
    candidates (owner, rec) = map (candidate (base owner rec)) formats
    base owner rec = dir <> "/" <> show owner <> suffix rec
    suffix Azan     = ""
    suffix FajrAzan = "-fajr"
    formats = [("ogg", "audio/ogg"), ("mp3", "audio/mpeg"), ("m4a", "audio/mp4")]
    candidate b (ext, contentType) = (b <> "." <> ext, contentType)
    firstExisting [] = return Nothing
    firstExisting ((path, contentType) : rest) = do
      exists <- doesFileExist path
      if exists then return (Just (path, contentType)) else firstExisting rest

-- Which recordings a mosque has, its own or the default.
mosqueRecordings :: FilePath -> MosqueId -> IO [Recording]
mosqueRecordings dir mid = do
  found <- mapM (\r -> (\f -> (r, f)) <$> findRecording dir mid r) [minBound .. maxBound]
  return (map fst (filter (isJust . snd) found))

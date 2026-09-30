module Hilal.App (app) where

import Network.Wai (Application)
import Web.Scotty

app :: IO Application
app = scottyApp $ do
  get "/health" $
    text "ok"
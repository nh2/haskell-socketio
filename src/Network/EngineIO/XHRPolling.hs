{-# LANGUAGE OverloadedStrings, NamedFieldPuns, ExistentialQuantification #-}

module Network.EngineIO.XHRPolling
  ( main
  ) where

import Network.Wai
import Data.Monoid
import Network.Wai.Handler.Warp
import Control.Monad.Trans.Resource
import Control.Monad.IO.Class (liftIO)
import Network.HTTP.Types.Status
import Control.Concurrent
import Data.Map.Strict as Map (Map, insertLookupWithKey, updateLookupWithKey)
import qualified Data.Map.Strict as Map
import Data.UUID
import Data.UUID.V4 (nextRandom)
import Data.IORef
import Data.Maybe
import Control.Monad
import qualified Data.ByteString.Char8 as BS -- TODO import encoding instead of Char8?
import Control.Applicative

import Network.EngineIO

-- TODO use types or modules to make sure we always send a payload,
--      never accidentally a raw encoded packet

-- TODO restrict to /engine.io
-- STEP-1: Transport establishes a connection
app :: State -> Application
app State{ clientMapRef = cmr } Request{ queryString = queryItems } = runResourceT . liftIO $ do
  case fromMaybe "" <$> lookup "sid" queryItems of
    Just querySid -> do
      case fromString (BS.unpack querySid) of
        Nothing -> error "sid uuid in bad format" -- TODO handle bad UUID string format
        Just s  -> do m'client <- lookupClient s <$> readIORef cmr
                      case m'client of
                        Nothing -> do putStrLn $ "client with SID " ++ show s ++ " is not known"
                                      return $ responseLBS status200 [] "" -- TODO respond error
                        Just Client{ mvar } -> respondMvar mvar

    Nothing -> do
      -- A new client, put them into the clientMap and wait until they get a message
      m <- newEmptyMVar
      newSid <- nextRandom
      failed <- atomicWithClientMap cmr (addClient (Client m newSid))
      if failed
        then do
          putStrLn "client already polling"
          return $ responseLBS status200 [] "" -- TODO respond error
        else do
          -- STEP-2: Respond OPEN packet
          -- TODO make parameter
          -- TODO implement flashsocket, websocket
          let transports = [Polling] -- TODO should this be "Polling" instead?
          -- TODO use Builder
          let openPacket = Packet Open $ Just $ mconcat
                             [ "{ \"sid\": \"",       sid, "\""
                             , ", \"upgrades\": ",    upgrades
                             , ", \"pingTimeout\": ", pingTimeout
                             , " }"]
              sid = BS.pack (toString newSid)
              upgrades = encodeTransports transports
              -- TODO make parameter
              -- TODO is this ms? Check protocol
              pingTimeout = "1000"

          return $ responseLBS status200 [] $ encodePayload (Payload [openPacket])
  where
    respondMvar m = do
      payload <- takeMVar m
      return $ responseLBS status200 [] (encodePayload payload)

data Client = Client
  { mvar :: MVar Payload
  , sid :: UUID
  } deriving (Eq)

instance Show Client where
  show (Client _ sid) = "Client { sid = " ++ show sid ++ " }"

newtype ClientMap = ClientMap (Map UUID Client) deriving (Eq, Show)

data State = State
  { clientMapRef :: IORef ClientMap
  } deriving (Eq)

emptyClientMap :: ClientMap
emptyClientMap = ClientMap Map.empty


addClient :: Client -> ClientMap -> Maybe ClientMap
addClient client (ClientMap cm) = case insertLookupWithKey f (sid client) client cm of
  (Just _,  _) -> Nothing -- client was already in, that's bad
  (Nothing, m) -> Just (ClientMap m)
  where
    f _key old _new = old -- don't do anything (doesn't really matter, we return Nothing in that case)


lookupClient :: UUID -> ClientMap -> Maybe Client
lookupClient sid (ClientMap cm) = Map.lookup sid cm


removeClientBySID :: UUID -> ClientMap -> Maybe ClientMap
removeClientBySID sid (ClientMap cm) = case updateLookupWithKey f sid cm of
  (Nothing, _) -> Nothing -- client was not in, that's bad
  (Just _,  m) -> Just (ClientMap m)
  where
    f _key _old = Nothing -- remove the value


atomicWithClientMap :: IORef ClientMap -> (ClientMap -> Maybe ClientMap) -> IO Bool
atomicWithClientMap ref f = atomicModifyIORef ref $ \cm -> case f cm of
  Just newCm -> (newCm, False)
  Nothing    -> (cm,    True) -- this is the bad case


-- TODO remove
main :: IO ()
main = do
  state <- State <$> newIORef emptyClientMap

  _ <- forkIO $ forever $ do
    pingAllClients state
    threadDelay 1000000

  run 1234 $ app state

  where
    pingAllClients State{ clientMapRef = r } = do
      ClientMap cm <- readIORef r
      forM (Map.toList cm) $ \(_, Client{ mvar }) ->
        tryPutMVar mvar (Payload [Packet Message (Just "hello")])

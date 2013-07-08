{-# LANGUAGE OverloadedStrings, NamedFieldPuns, ExistentialQuantification #-}

module Network.EngineIO.XHRPolling
  ( main
  ) where

import Network.Wai
import Data.Monoid
import Data.Conduit
import Data.Conduit.Binary (sinkLbs)
import Network.Wai.Handler.Warp
import Control.Monad.IO.Class
import Network.HTTP.Types.Status
import Network.HTTP.Types.Method
import Control.Concurrent
import Data.Map.Strict as Map (Map, insertLookupWithKey, updateLookupWithKey)
import qualified Data.Map.Strict as Map
import Data.UUID
import Data.UUID.V4 (nextRandom)
import Data.IORef
import Data.Maybe
import Control.Monad
import qualified Data.ByteString.Char8 as BS -- TODO import encoding instead of Char8?
import qualified Data.ByteString.Lazy.Char8 as BSL
import Control.Applicative

import Network.EngineIO

-- TODO use types or modules to make sure we always send a payload,
--      never accidentally a raw encoded packet

-- TODO restrict to /engine.io
-- STEP-1: Transport establishes a connection
app :: State -> Application
app State{ clientMapRef = cmr } Request{ requestMethod = method, queryString = queryItems, requestBody = body, requestBodyLength = bodyLength }
  | method == methodGet  = runResourceT . liftIO $ handleGet
  | method == methodPost = handlePost
  | otherwise            = warn "bad method"
  where

    withClient :: (MonadIO m) => BS.ByteString -> (Client -> m Response) -> m Response
    withClient sid f = case fromString (BS.unpack sid) of
      Nothing -> warn "sid uuid in bad format"
      Just s  -> do m'client <- lookupClient s `liftM` liftIO (readIORef cmr)
                    case m'client of
                      Nothing -> warn $ "client with SID " ++ show s ++ " is not known"
                      Just c  -> f c

    handleGet = case fromMaybe "" <$> lookup "sid" queryItems of
      Just querySid -> withClient querySid $ \Client{ mvar } -> respondMvar mvar

      Nothing -> do
        -- A new client, put them into the clientMap and wait until they get a message
        m <- newEmptyMVar
        newSid <- nextRandom
        failed <- atomicWithClientMap cmr (addClient (Client m newSid))
        if failed
          then warn "client already polling"
          else do
            -- STEP-2: Respond OPEN packet
            -- TODO make parameter
            -- TODO implement flashsocket, websocket
            let transports = [Polling] -- TODO should this be "Polling" instead?
            -- TODO use Builder
            let openPacket = Packet Open $ Just $ mconcat
                               [ "{ \"sid\": \"",        sid, "\""
                               , ", \"upgrades\": ",     upgrades
                               , ", \"pingTimeout\": ",  pingTimeout
                               , ", \"pingInterval\": ", pingInterval
                               , " }"]
                sid = BS.pack (toString newSid)
                upgrades = encodeTransports transports
                -- TODO make parameter
                -- TODO is this ms? Check protocol
                pingTimeout  = "1000"
                pingInterval = "1000"

            respondOk $ encodePayload (Payload [openPacket])

    handlePost = case fromMaybe "" <$> lookup "sid" queryItems of
      Nothing       -> warn "missing sid"
      Just querySid -> withClient querySid $ \Client{ mvar } -> do
        case bodyLength of
          ChunkedBody -> warn "chunked POSTs are not allowed"
          KnownLength _ -> do
            allBody <- body $$ sinkLbs -- sinkLBS forces the whole LBS already
            case decodePayload (BSL.toStrict allBody) of
              Left err                -> warn err
              Right (Payload [])      -> warn "no packets in client payload"
              Right (Payload packets) -> go packets
                where
                  -- TODO use some maybe construction for this, manual looping bah
                  go []     = respondOk "" -- all fine
                  go (p:ps) = do
                    case p of
                      Packet Ping _ -> do liftIO $ putStrLn "responding ping with pong ..."
                                          liftIO . putMVar mvar $ Payload [Packet Pong Nothing]
                                          liftIO $ putStrLn "responded pong"
                                          go ps
                      Packet Close _ -> do liftIO $ putStrLn "received close"
                                           -- TODO not sure if we should send noop; we have to put something into the mvar
                                           liftIO . putMVar mvar $ Payload [Packet Noop Nothing]
                                           go ps
                      Packet typ _  -> warn $ "unhandled POST packet type " ++ show typ
                                       -- don't process remaining packages ps


    respondMvar m = do
      payload <- takeMVar m
      respondOk (encodePayload payload)

    respondOk bs = return $ responseLBS status200 [] bs

    warn msg = do
      liftIO $ putStrLn msg
      return $ responseLBS status500 [] (BSL.pack msg) -- TODO send some proper json?

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

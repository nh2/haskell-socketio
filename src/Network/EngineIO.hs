{-# LANGUAGE OverloadedStrings #-}

module Network.EngineIO
  (-- * Packets, Payloads and Transports
    PacketType (..)
  , Packet (..)
  , Payload (..)
  , Transport (..)
  , packetTypeLabel

  -- * Packets
  , encodePacket
  , decodePacket

  -- * Payloads
  , encodePayload
  , decodePayload
  ) where

import Control.Applicative
import Data.Monoid
import Data.Maybe
import Data.ByteString (ByteString)
import Data.ByteString.Lazy.Builder (byteString, toLazyByteString)
import Data.ByteString.Lazy.Builder.ASCII (intDec)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Attoparsec.Char8 as A


-- * Packets, Payloads and Transports

-- | See <https://github.com/LearnBoost/engine.io-client/blob/master/SPEC.md>.
data PacketType = Open
                | Close
                | Ping
                | Pong
                | Message
                | Upgrade
                | Noop
                deriving (Bounded, Eq, Enum, Ord, Show)


data Packet = Packet PacketType (Maybe ByteString)
            deriving (Eq, Show)

-- | Invariant: There is at least one packet
data Payload = Payload [Packet]
             deriving (Eq, Show)


data Transport = Websocket
               | Flashsocket
               | Jsonp       -- ^ Polling
               | Xhr         -- ^ Polling
               deriving (Eq, Show)


packetTypeLabel :: PacketType -> ByteString
packetTypeLabel t = case t of
  Open    -> "open"
  Close   -> "close"
  Ping    -> "ping"
  Pong    -> "pong"
  Message -> "message"
  Upgrade -> "upgrade"
  Noop    -> "noop"


packetTypeFromNumber :: Int -> Either String PacketType
packetTypeFromNumber n = case n of
  0 -> Right Open
  1 -> Right Close
  2 -> Right Ping
  3 -> Right Pong
  4 -> Right Message
  5 -> Right Upgrade
  6 -> Right Noop
  _ -> Left $ show n ++ " is not an engine.io packet type"


-- * Helpers

asParser :: (a -> Either String b) -> Parser a -> Parser b
asParser f p = do x <- p
                  either fail return (f x)

subParser :: Parser a -> ByteString -> Parser a
subParser p bs = case parseOnly p bs of
  Left err -> fail err
  Right x  -> return x


parserError :: String
parserError = "parser error"


-- * Packets


-- TODO don't use show
-- | Encodes a packet.
--
-- ><packet type id> [ `:` <data> ]
--
-- Example:
--
-- >5:hello world
-- >3
-- >4
encodePacket :: Packet -> ByteString
encodePacket (Packet t m'msg) = packetTypeLabel t <> fromMaybe "" m'msg


-- | Decodes a packet. See `encodePacket`.
decodePacket :: ByteString -> Either String Packet
decodePacket = parseOnly parsePacket


-- | Parses a packet. See `encodePacket`.
parsePacket :: Parser Packet
parsePacket = do
  typ <- packetTypeFromNumber `asParser` decimal
  msg <- takeByteString
  if BS.null msg then return $ Packet typ Nothing
                 else return $ Packet typ (Just (msg))


-- * Payloads

-- | Encodes multiple messages (payload).
--
-- ><length>:data
--
-- Example:
--
-- >11:hello world2:hi
encodePayload :: Payload -> ByteString
encodePayload (Payload ps) = BSL.toStrict . toLazyByteString $
  mconcat [ intDec (BS.length msg) <> byteString msg | msg <- map encodePacket ps ]


-- TODO What does this sentence mean?
-- | Decodes data when a payload is maybe expected.
decodePayload :: ByteString -> Either String Payload
decodePayload = parseOnly parsePayload


parsePayload :: Parser Payload
parsePayload = (Payload <$>) . (<?> parserError) $ many1' $ do
  n <- decimal
  _ <- char ':'
  msg <- A.take n
  subParser parsePacket msg

module Control.Parallel.MPI.Serializable
   ( send
   , bsend
   , ssend
   , rsend
   , sendBS
   , recv
   , recvBS
   , isend
   , ibsend
   , issend
   , isendBS
   , Future
   , cancelFuture
   , pollFuture
   , waitFuture
   , getFutureStatus
   , recvFuture
   , bcast
   , sendGather
   , recvGather
   , sendScatter
   , recvScatter
   ) where

import C2HS
import Control.Concurrent (forkIO, ThreadId, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, tryTakeMVar, readMVar, putMVar)
import Data.ByteString.Unsafe as BS
import qualified Data.ByteString as BS
import Data.Serialize (encode, decode, Serialize)
import qualified Control.Parallel.MPI.Internal as Internal
import Control.Parallel.MPI.Datatype as Datatype
import Control.Parallel.MPI.Comm as Comm
import Control.Parallel.MPI.Request as Request
import Control.Parallel.MPI.Status as Status
import Control.Parallel.MPI.Utils (checkError)
import Control.Parallel.MPI.Tag as Tag
import Control.Parallel.MPI.Rank as Rank
import Control.Parallel.MPI.Common (probe, commRank, commSize)
import qualified Data.Array.Storable as SA
import Data.List (unfoldr)

send, bsend, ssend, rsend :: Serialize msg => Comm -> Rank -> Tag -> msg -> IO ()
send  c r t m = sendBSwith Internal.send  c r t $ encode m
bsend c r t m = sendBSwith Internal.bsend c r t $ encode m
ssend c r t m = sendBSwith Internal.ssend c r t $ encode m
rsend c r t m = sendBSwith Internal.rsend c r t $ encode m

sendBS :: Comm -> Rank -> Tag -> BS.ByteString -> IO ()
sendBS = sendBSwith Internal.send

sendBSwith ::
  (Ptr () -> CInt -> Datatype -> CInt -> CInt -> Comm -> IO CInt) ->
  Comm -> Rank -> Tag -> BS.ByteString -> IO ()
sendBSwith send_function comm rank tag bs = do
   let cRank = fromRank rank
       cTag  = fromTag tag
       cCount = cIntConv $ BS.length bs
   unsafeUseAsCString bs $ \cString ->
       checkError $ send_function (castPtr cString) cCount byte cRank cTag comm

recv :: Serialize msg => Comm -> Rank -> Tag -> IO (msg, Status)
recv comm rank tag = do
   (bs, status) <- recvBS comm rank tag
   case decode bs of
      Left e -> fail e
      Right val -> return (val, status)

recvBS :: Comm -> Rank -> Tag -> IO (BS.ByteString, Status)
recvBS comm rank tag = do
   probeStatus <- probe rank tag comm
   let count = status_count probeStatus
       cSource = fromRank rank
       cTag    = fromTag tag
       cCount  = cIntConv count
   allocaBytes count
      (\bufferPtr ->
          alloca $ \statusPtr -> do
             checkError $ Internal.recv bufferPtr cCount byte cSource cTag comm $ castPtr statusPtr
             recvStatus <- peek statusPtr
             message <- BS.packCStringLen (castPtr bufferPtr, count)
             return (message, recvStatus))

isend, ibsend, issend :: Serialize msg => Comm -> Rank -> Tag -> msg -> IO Request
isend  c r t m = isendBSwith Internal.isend  c r t $ encode m
ibsend c r t m = isendBSwith Internal.ibsend c r t $ encode m
issend c r t m = isendBSwith Internal.issend c r t $ encode m

isendBS :: Comm -> Rank -> Tag -> BS.ByteString -> IO Request
isendBS = isendBSwith Internal.isend

isendBSwith ::
  (Ptr () -> CInt -> Datatype -> CInt -> CInt -> Comm -> Ptr (Request) -> IO CInt) ->
  Comm -> Rank -> Tag -> BS.ByteString -> IO Request
isendBSwith send_function comm rank tag bs = do
   let cRank = fromRank rank
       cTag  = fromTag tag
       cCount = cIntConv $ BS.length bs
   alloca $ \requestPtr ->
      unsafeUseAsCString bs $ \cString -> do
          checkError $ send_function (castPtr cString) cCount byte cRank cTag comm requestPtr
          peek requestPtr

data Future a =
   Future
   { futureThread :: ThreadId
   , futureStatus :: MVar Status
   , futureVal :: MVar a
   }

waitFuture :: Future a -> IO a
waitFuture = readMVar . futureVal

getFutureStatus :: Future a -> IO Status
getFutureStatus = readMVar . futureStatus

pollFuture :: Future a -> IO (Maybe a)
pollFuture = tryTakeMVar . futureVal

-- May want to stop people from waiting on Futures which are killed...
cancelFuture :: Future a -> IO ()
cancelFuture = killThread . futureThread

recvFuture :: Serialize msg => Comm -> Rank -> Tag -> IO (Future msg)
recvFuture comm rank tag = do
   valRef <- newEmptyMVar
   statusRef <- newEmptyMVar
   -- is forkIO acceptable here? Depends on thread local stateness of MPI.
   -- threadId <- forkOS $ do
   threadId <- forkIO $ do
      -- do a synchronous recv in another thread
      (msg, status) <- recv comm rank tag
      putMVar valRef msg
      putMVar statusRef status
   return $ Future { futureThread = threadId, futureStatus = statusRef, futureVal = valRef }

{- Broadcast is tricky because the receiver doesn't know how much memory to allocate.
   The C interface assumes the sender and receiver agree on the size in advance, but
   this is not useful for the Haskell interface (where we want to send arbitrary sized
   values) because the sender is the only process which has the actual data available

   The work around is for the sender to send two messages. The first says how much data
   is coming. The second message sends the actual data. We rely on the two messages being
   sent and received in this order. Conversely the receiver gets two messages. The first is
   the size of memory to allocate and the second in the actual message.

   The obvious downside of this approach is that it requires two broadcasts for one
   payload. Communication costs can be expensive.

   The idea for this scheme was inspired by the Ocaml bindings. Therefore there is
   some precedent for doing it this way.
-}

bcast :: Serialize msg => Comm -> Rank -> msg -> IO msg
bcast comm rootRank msg = do
   myRank <- commRank comm
   let cRank  = fromRank rootRank
   if myRank == rootRank
      then do
         let bs = encode msg
             cCount = cIntConv $ BS.length bs
         -- broadcast the size of the message first
         alloca $ \ptr -> do
            poke ptr cCount
            let numberOfInts = 1::CInt
            checkError $ Internal.bcast (castPtr ptr) numberOfInts int cRank comm
         -- then broadcast the actual message
         unsafeUseAsCString bs $ \cString -> do
            checkError $ Internal.bcast (castPtr cString) cCount byte cRank comm
         return msg
      else do
         -- receive the broadcast of the size
         count <- alloca $ \ptr -> do
            checkError $ Internal.bcast (castPtr ptr) 1 int cRank comm
            peek ptr
         -- receive the broadcast of the message
         allocaBytes count $
            \bufferPtr -> do
               let cCount = cIntConv count
               checkError $ Internal.bcast bufferPtr cCount byte cRank comm
               bs <- BS.packCStringLen (castPtr bufferPtr, count)
               case decode bs of
                  Left e -> fail e
                  Right val -> return val

-- List should have exactly numProcs elements
sendGather :: Serialize msg => Comm -> Rank -> msg -> IO ()
sendGather comm root msg = do
  let enc_msg = encode msg
      len = cIntConv $ BS.length enc_msg
  -- Send length
  alloca $ \ptr -> do
    poke ptr len
    checkError $ Internal.gather (castPtr ptr) (1::CInt) int nullPtr 0 int (fromRank root) comm
  -- Send payload
  unsafeUseAsCString enc_msg $ \cString -> do
    checkError $ Internal.gatherv (castPtr cString) len byte nullPtr nullPtr nullPtr byte (fromRank root) comm
  
recvGather :: Serialize msg => Comm -> Rank -> msg -> IO [msg]
recvGather comm root msg = do
  let enc_msg = encode msg
      len = cIntConv $ BS.length enc_msg
  numProcs <- commSize comm
  unsafeUseAsCString enc_msg $ \sendPtr -> do
    alloca $ \ptr -> do
      poke ptr len
      -- receive array of numProcs ints - sizes of payloads to be send by other processes
      lengthsArr <- SA.newArray_ (0,numProcs-1) :: IO (SA.StorableArray Int CInt)
      SA.withStorableArray lengthsArr $ \countsPtr -> do
        checkError $ Internal.gather (castPtr ptr) (1::CInt) int (castPtr countsPtr) (1::CInt) int (fromRank root) comm
      -- calculate displacements from sizes
      lengths <- SA.getElems lengthsArr
      displ <- SA.newListArray (0,numProcs-1) $ Prelude.init $ scanl1 (+) (0:lengths) :: IO (SA.StorableArray Int CInt)
      let payload_len = cIntConv $ sum lengths
      -- receive payloads
      SA.withStorableArray displ $ \displPtr ->
        SA.withStorableArray lengthsArr $ \countsPtr ->
          allocaBytes payload_len $ \recvPtr -> do
            checkError $ Internal.gatherv (castPtr sendPtr) len byte recvPtr countsPtr displPtr byte (fromRank root) comm
            -- decode payloads
            bs <- BS.packCStringLen (castPtr recvPtr, payload_len)
            return $ decodeList (map fromIntegral lengths) bs

decodeList :: (Serialize msg) => [Int] -> BS.ByteString -> [msg]
decodeList lengths bs = unfoldr decodeNext (lengths,bs)
  where
    decodeNext ([],_) = Nothing
    decodeNext ((l:ls),bs) = 
      case decode bs of
        Left e -> fail e
        Right val -> Just (val, (ls, BS.drop l bs))
        
recvScatter :: Serialize msg => Comm -> Rank -> IO msg
recvScatter comm root = do
  -- Recv length
  len <- alloca $ \ptr -> do
    checkError $ Internal.scatter nullPtr 0 int (castPtr ptr) (1::CInt) int (fromRank root) comm
    peek ptr
  -- Recv payload
  allocaBytes len $ \recvPtr -> do
    checkError $ Internal.scatterv nullPtr nullPtr nullPtr byte (castPtr recvPtr) (cIntConv len) byte (fromRank root) comm
    bs <- BS.packCStringLen (castPtr recvPtr, len)
    case decode bs of
      Left e -> fail e
      Right val -> return val
    
-- List should have exactly numProcs elements  
sendScatter :: Serialize msg => Comm -> Rank -> [msg] -> IO msg
sendScatter comm root msgs = do
  let enc_msgs = map encode msgs
      lengths = map (cIntConv . BS.length) enc_msgs
      payload = BS.concat enc_msgs
  numProcs <- commSize comm
  unsafeUseAsCString payload $ \sendPtr -> do
    alloca $ \myLenPtr -> do
      -- scatter numProcs ints - sizes of payloads to be sent to other processes
      lengthsArr <- SA.newListArray (0,numProcs-1) lengths :: IO (SA.StorableArray Int CInt)
      SA.withStorableArray lengthsArr $ \countsPtr -> do
        checkError $ Internal.scatter (castPtr countsPtr) (1::CInt) int (castPtr myLenPtr) (1::CInt) int (fromRank root) comm
      myLen <- peek myLenPtr
      -- calculate displacements from sizes
      displ <- SA.newListArray (0,numProcs-1) $ Prelude.init $ scanl1 (+) (0:lengths) :: IO (SA.StorableArray Int CInt)
      -- scatter payloads
      SA.withStorableArray displ $ \displPtr ->
        SA.withStorableArray lengthsArr $ \countsPtr ->
          allocaBytes myLen $ \recvPtr -> do
            checkError $ Internal.scatterv (castPtr sendPtr) (castPtr countsPtr) (castPtr displPtr) byte recvPtr (cIntConv myLen) byte (fromRank root) comm
            -- decode out payload
            bs <- BS.packCStringLen (castPtr recvPtr, myLen)
            case decode bs of
              Left e -> fail e
              Right val -> return val
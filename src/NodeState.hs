{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module NodeState
  (

  -- ** Node Data Structures

    NodeState(..)
  , initNodeState
  , resetNodeState

  , NodeAccType(..)

  , NodeConfig(..)
  , initNodeConfig

  , NodeEnv(..)
  , initNodeEnv

  , NodeT
  , runNodeT

  -- ** Getters & Setters
  , askAccount
  , askPrivateKey
  , askKeyPair
  , askAccountType
  , askSelfAddress
  , askGenesisBlock
  , askNodeDataFilePaths
  , askPeersFilePath
  , askNetworkAccessToken

  -- ** World State
  , getLedger
  , setLedger

  -- ** Node Peers
  , getPeers
  , getPeerNodeIds
  , setPeers
  , withPeers
  , modifyPeers
  , modifyPeers_

  -- ** Memory Pool
  , appendTxMemPool
  , getTxMemPool
  , resetTxMemPool
  , pruneTxMemPool
  , removeTxsFromMemPool
  , elemTxMemPool
  , elemInvalidTxPool
  , isTestNode
  , getTxStatus

  -- ** Invalid tx pool
  , appendInvalidTxPool
  , getInvalidTxPool

  -- ** Query Ledger State
  , lookupAccount
  , withLedgerState

  -- ** World State
  , verifyValidateAndApplyBlock
  , syncNodeStateWithDBs

  -- ** Consensus
  , getPoAState
  , setPoAState
  , modifyPoAState_
  , withPoAState
  , getLastBlock
  , setLastBlock
  , isValidatingNode
  , getValidatorPeers

  -- ** Preallocated Accounts
  , loadPreallocatedAccs

  , withApplyCtx

  ) where

import Protolude hiding (try)

import qualified Control.Concurrent.MVar.Lifted as MVarL

import Control.Arrow ((&&&))

import Control.Monad.Base
import Control.Monad.Trans.Class
import Control.Monad.Trans.Control

import Control.Distributed.Process.Lifted
import Control.Distributed.Process.Lifted.Class

import qualified Data.DList as DL
import qualified Data.Map as Map
import qualified Data.Set as Set

import DB

import Address (Address, AAccount)
import Block (Block)
import qualified Account
import qualified Block
import qualified Key
import qualified Network.P2P.Logging as Log
import qualified Ledger
import qualified Transaction as Tx
import qualified TxLog
import qualified MemPool
import qualified Encoding as E
import qualified Hash as H
import qualified Validate as V

import Node.Peer
import Node.Files (NodeData(..), NodeDataFilePaths(..))

import qualified Consensus.Authority.Params as CAP
import qualified Consensus.Authority.State as CAS


-------------------------------------------------------------------------------
-- NodeEnv (NodeState & NodeConfig)
-------------------------------------------------------------------------------

data NodeState = NodeState
  { ledger        :: MVar Ledger.World          -- ^ In-memory world-state
  , p2pPeers      :: MVar Peers                 -- ^ Known peers in p2p network
  , txPool        :: MVar MemPool.MemPool       -- ^ Transactions memory pool
  , invalidTxPool :: MVar MemPool.InvalidTxPool -- ^ Invalid transactions that cannot be applied
  , poaState      :: MVar CAS.PoAState          -- ^ Stateful values related to consensus
  , lastBlock     :: MVar Block.Block           -- ^ Last block in the chain
  }

data NodeAccType = New | Existing

data NodeConfig = NodeConfig
  { account      :: Account.Account    -- ^ Active account
  , privKey      :: Key.PrivateKey     -- ^ Active account's private key
  , accountType  :: NodeAccType        -- ^ Is account new or existing
  , preallocated :: FilePath           -- ^ Directory for preallocated accounts
  , testMode     :: Bool               -- ^ If the node is in "test" mode or not
  , dataFilePaths :: NodeDataFilePaths -- ^ File paths to node data store on disk
  , genesisBlock :: Block.Block        -- ^ Network genesis block
  , accessToken  :: Key.ECDSAKeyPair   -- ^ Network access token
  }

initNodeState
  :: MonadBase IO m
  => Ledger.World          -- ^ Initial World State
  -> Peers                 -- ^ Node Peers
  -> MemPool.MemPool       -- ^ Initial MemPool
  -> MemPool.InvalidTxPool -- ^ Initial MemPool
  -> CAS.PoAState          -- ^ Initial PoA State
  -> Block.Block           -- ^ Last Block in Chain
  -> m NodeState
initNodeState w ps mp itxp poa blk = do
  ledger <- liftBase (newMVar w)
  p2pPeers <- liftBase (newMVar ps)
  txPool <- liftBase (newMVar mp)
  invalidTxPool <- liftBase (newMVar itxp)
  poaState <- liftBase (newMVar poa)
  lastBlock <- liftBase (newMVar blk)
  return NodeState{..}

-- | Resets all of NodeState except for peers
resetNodeState
  :: (MonadProcess m, MonadReadDB m)
  => NodeT m ()
resetNodeState = do
  resetLedger
  resetTxMemPool
  resetInvalidTxPool
  resetPoAState
  resetLastBlock

initNodeConfig
  :: NodeData          -- ^ Data structure containing most node config info
  -> NodeDataFilePaths -- ^ File paths to data a node stores outside of the DB
  -> NodeAccType       -- ^ Is the node account new or existing
  -> Block             -- ^ The genesis block
  -> FilePath          -- ^ Filepath to the preallocated network accounts
  -> Bool              -- ^ Is the node in test mode
  -> Key.ECDSAKeyPair  -- ^ Network Access Token
  -> NodeConfig
initNodeConfig nd ndfps nacctyp gblk preall test atok =
  NodeConfig
    { account       = nodeAccount nd
    , privKey       = snd (nodeKeys nd)
    , accountType   = nacctyp
    , preallocated  = preall
    , testMode      = test
    , dataFilePaths = ndfps
    , genesisBlock  = gblk
    , accessToken   = atok
    }

data NodeEnv = NodeEnv
  { nodeConfig :: NodeConfig
  , nodeState  :: NodeState
  }

data NodeEnvInitError
  = InvalidItxPoolSize Int
  deriving (Show)

initNodeEnv
  :: MonadBase IO m
  => NodeData          -- ^ Data structure containing most node config info
  -> NodeDataFilePaths -- ^ File paths to data a node stores outside of the DB
  -> NodeAccType       -- ^ Is the node account new or existing
  -> Block             -- ^ The genesis block
  -> FilePath          -- ^ Filepath to the preallocated network accounts
  -> Bool              -- ^ Is the node in test mode
  -> Key.ECDSAKeyPair  -- ^ Is the node in test mode
  -> Ledger.World      -- ^ Initial World State
  -> Peers             -- ^ Node Peers
  -> MemPool.MemPool   -- ^ Initial MemPool
  -> Int               -- ^ Number of latest invalid transactions to cache
  -> CAS.PoAState      -- ^ Initial PoA State
  -> Block.Block       -- ^ Last Block in Chain
  -> m (Either NodeEnvInitError NodeEnv)
initNodeEnv nd ndfps nacctyp gblk preall test atok w ps mp nitxs poas lblk = do
  let eInvalidTxPool = MemPool.mkInvalidTxPool nitxs
  case eInvalidTxPool of
    Left _ -> pure $ Left $ InvalidItxPoolSize nitxs
    Right itxmp -> do
      nodeState <- initNodeState w ps mp itxmp poas lblk
      pure $ Right $ NodeEnv nodeConfig nodeState
  where
    nodeConfig =
      initNodeConfig nd ndfps nacctyp gblk preall test atok

--------------------------------------------------------------------------------
-- NodeT Monad Transformer
--------------------------------------------------------------------------------

newtype NodeT m a = NodeT { unNodeT :: ReaderT NodeEnv m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadTrans, MonadReader NodeEnv)

-- | Run a computation with access to NodeConfig environment and NodeState
-- state, with any base monad as long as MonadBase IO is implemented
runNodeT :: NodeEnv -> NodeT m a -> m a
runNodeT nodeEnv = flip runReaderT nodeEnv . unNodeT

--------------------------------------------------------------------------------
-- MonadBase/Control/TransControl Boilerplate
--------------------------------------------------------------------------------

instance MonadBase IO m => MonadBase IO (NodeT m) where
  liftBase = liftBaseDefault

instance MonadTransControl NodeT where
  type StT NodeT a = StT (ReaderT NodeEnv) a
  liftWith = defaultLiftWith NodeT unNodeT
  restoreT = defaultRestoreT NodeT

instance MonadBaseControl IO m => MonadBaseControl IO (NodeT m) where
  type StM (NodeT m) a = ComposeSt NodeT m a
  liftBaseWith = defaultLiftBaseWith
  restoreM     = defaultRestoreM

instance MonadProcess m => MonadProcess (NodeT m) where
  liftP = NodeT . liftP

instance MonadProcessBase m => MonadProcessBase (NodeT m) where
  type StMP (NodeT m) a = ComposeStP (ReaderT NodeEnv) m a
  liftBaseWithP = defaultLiftBaseWithP
  restoreMP = defaultRestoreMP

-------------------------------------------------------------------------------
-- NodeState Utils
-------------------------------------------------------------------------------

readMVar' :: MonadBase IO m => (a -> b) -> MVar a -> m b
readMVar' f = liftBase . fmap f . readMVar

modifyNodeState_
  :: MonadBase IO m
  => (NodeState -> MVar a)
  -> (a -> IO a)
  -> NodeT m ()
modifyNodeState_ g f = do
  mvar <- getNodeState g
  liftBase $ modifyMVar_ mvar f

modifyNodeState
  :: MonadBase IO m
  => (NodeState -> MVar a)
  -> (a -> IO (a,b))
  -> NodeT m b
modifyNodeState g f = do
  mvar <- getNodeState g
  liftBase $ modifyMVar mvar f

-- | Modify the node state MVar atomically but allow reading the database within
-- the body of the modification function.
modifyNodeStateReadDB_
  :: (MonadReadDB m, MonadBaseControl IO m)
  => (NodeState -> MVar a)
  -> (a -> NodeT m (a,b))
  -> NodeT m b
modifyNodeStateReadDB_ g f = do
  mvar <- getNodeState g
  MVarL.modifyMVar mvar f

-------------------------------------------------------------------------------
-- Getters & Setters
-------------------------------------------------------------------------------

askNodeConfig :: Monad m => NodeT m NodeConfig
askNodeConfig = asks nodeConfig

getNodeState :: Monad m => (NodeState -> MVar a) -> NodeT m (MVar a)
getNodeState f = f <$> asks nodeState

askAccount :: Monad m => NodeT m Account.Account
askAccount = account <$> askNodeConfig

askPrivateKey :: Monad m => NodeT m Key.PrivateKey
askPrivateKey = privKey <$> askNodeConfig

askKeyPair :: Monad m => NodeT m Key.ECDSAKeyPair
askKeyPair = (Key.toPublic &&& identity) <$> NodeState.askPrivateKey

askAccountType :: Monad m => NodeT m NodeAccType
askAccountType = accountType <$> askNodeConfig

askSelfAddress :: Monad m => NodeT m (Address AAccount)
askSelfAddress = Account.address <$> askAccount

askGenesisBlock :: Monad m => NodeT m Block.Block
askGenesisBlock = genesisBlock <$> askNodeConfig

askNodeDataFilePaths :: Monad m => NodeT m NodeDataFilePaths
askNodeDataFilePaths = dataFilePaths <$> askNodeConfig

askPeersFilePath :: Monad m => NodeT m FilePath
askPeersFilePath = Node.Files.peersFile <$> askNodeDataFilePaths

askTxLogFilePath :: Monad m => NodeT m FilePath
askTxLogFilePath = Node.Files.txLogFile <$> askNodeDataFilePaths

askNetworkAccessToken :: Monad m => NodeT m Key.ECDSAKeyPair
askNetworkAccessToken = accessToken <$> askNodeConfig

-------------------------------------------------------------------------------

getLedger :: MonadBase IO m => NodeT m Ledger.World
getLedger = liftBase . readMVar =<< getNodeState ledger

setLedger :: MonadBase IO m => Ledger.World -> NodeT m ()
setLedger ledger' = modifyNodeState_ ledger $ const $ pure ledger'

-- | Reset the ledger to it's initial state with preallocated accounts
resetLedger :: MonadProcess m => NodeT m ()
resetLedger = do
  eAccs <- loadPreallocatedAccs
  let eFreshWorld = first show .
        flip Ledger.addAccounts mempty =<< eAccs
  case eFreshWorld of
    Left err         -> Log.warning $ show err
    Right freshWorld -> setLedger freshWorld

withLedgerState :: MonadBase IO m => (Ledger.World -> NodeT m a) -> NodeT m a
withLedgerState f = f =<< getLedger

modifyLedgerState_ :: MonadBase IO m => (Ledger.World -> Ledger.World) -> NodeT m ()
modifyLedgerState_ f = modifyNodeState_ ledger $ pure . f

withPeers :: MonadBase IO m => (Peers -> NodeT m a) -> NodeT m a
withPeers f = f =<< getPeers

getPeers :: MonadBase IO m => NodeT m Peers
getPeers = liftBase . readMVar =<< getNodeState p2pPeers

getPeerNodeIds :: MonadBase IO m => NodeT m [NodeId]
getPeerNodeIds = peersToNodeIds <$> getPeers

getPoAState :: MonadBase IO m => NodeT m CAS.PoAState
getPoAState = liftBase . readMVar =<< getNodeState poaState

setPoAState :: MonadBase IO m => CAS.PoAState -> NodeT m ()
setPoAState pstate =
  modifyNodeState_ poaState $ const $ pure pstate

modifyPoAState_ :: MonadBase IO m => (CAS.PoAState -> CAS.PoAState) -> NodeT m ()
modifyPoAState_ f = modifyNodeState_ poaState $ pure . f

-- | Holds onto the poa state mvar while performing the computation
withPoAState :: MonadBase IO m => (CAS.PoAState -> NodeT m a) -> NodeT m a
withPoAState f = do
  poaMV <- getNodeState poaState
  poa <- liftBase $ takeMVar poaMV
  res <- f poa
  liftBase $ putMVar poaMV poa
  pure res

resetPoAState :: MonadBase IO m => NodeT m ()
resetPoAState = setPoAState CAS.defPoAState

getLastBlock :: MonadBase IO m => NodeT m Block.Block
getLastBlock = liftBase . readMVar =<< getNodeState lastBlock

setLastBlock :: MonadBase IO m => Block.Block -> NodeT m ()
setLastBlock = modifyNodeState_ lastBlock . const . pure

resetLastBlock :: MonadReadDB m => NodeT m ()
resetLastBlock = setLastBlock =<< askGenesisBlock

setPeers :: MonadBase IO m => Peers -> NodeT m ()
setPeers = modifyNodeState_ p2pPeers . const .  pure

-- | Modify peers atomically
modifyPeers_ :: MonadBase IO m => (Peers -> Peers) -> NodeT m ()
modifyPeers_ f = modifyNodeState_ p2pPeers $ pure . f

-- | Modify peers atomically, returning a result
modifyPeers :: MonadBase IO m => (Peers -> (Peers,a)) -> NodeT m a
modifyPeers f = modifyNodeState p2pPeers $ pure . f

getInvalidTxPool :: MonadBase IO m => NodeT m MemPool.InvalidTxPool
getInvalidTxPool = liftBase . readMVar =<< getNodeState invalidTxPool

-- | Insert invalid transactions into InvalidTxPool & InvalidTxDB
appendInvalidTxPool
  :: (MonadBaseControl IO m, MonadWriteDB m)
  => [Tx.InvalidTransaction]
  -> NodeT m (Either (DBError m) ())
appendInvalidTxPool itxs = do
  appendInvalidTxPool' itxs
  appendInvalidTxsDB itxs

-- | Insert invalid transactions into InvalidTxPool
appendInvalidTxPool' :: MonadBase IO m => [Tx.InvalidTransaction] -> NodeT m ()
appendInvalidTxPool' itxs = modifyNodeState_ invalidTxPool $ pure . MemPool.addInvalidTxs itxs

-- | Insert invalid transactions into InvalidTxDB
appendInvalidTxsDB
  :: (MonadBaseControl IO m, MonadWriteDB m)
  => [Tx.InvalidTransaction]
  -> NodeT m (Either (DBError m) ())
appendInvalidTxsDB =
  lift . DB.writeInvalidTxs

elemInvalidTxPool :: MonadBase IO m => H.Hash E.Base16ByteString -> NodeT m Bool
elemInvalidTxPool txHash = pure . MemPool.elemInvalidTxPool txHash =<< getInvalidTxPool

-- | Purge the contents of InvalidTxpool
resetInvalidTxPool :: MonadBase IO m => NodeT m ()
resetInvalidTxPool = modifyNodeState_ invalidTxPool $ pure . MemPool.resetInvalidTxPool

-- | Insert transaction into transaction pool. Returns True if successful.
appendTxMemPool :: MonadBase IO m => Tx.Transaction -> NodeT m Bool
appendTxMemPool tx =
  modifyNodeState txPool $ \memPool ->
    case MemPool.appendTx tx memPool of
      Nothing         -> pure (memPool, False)
      Just newMemPool -> pure (newMemPool, True)

getTxMemPool :: MonadBase IO m => NodeT m MemPool.MemPool
getTxMemPool = liftBase . readMVar =<< getNodeState txPool

resetTxMemPool :: MonadBase IO m => NodeT m ()
resetTxMemPool = modifyNodeState_ txPool $ const $ pure MemPool.emptyMemPool

-- | Atomically remove all invalid transactions from the mempool
-- and return the valid transactions.
pruneTxMemPool
  :: (MonadBaseControl IO m, MonadReadDB m)
  => NodeT m ([Tx.Transaction],[Tx.InvalidTransaction])
pruneTxMemPool =
  withLedgerState $ \world -> do
    modifyNodeStateReadDB_ txPool $ \memPool -> do
      let memPoolTxs = DL.toList $ MemPool.transactions $ memPool
      (_,invalidTxs,_) <-
        withApplyCtx $ \applyCtx -> do
          -- Validate transactions, collecting the invalid ones
          let applyState = V.initApplyState world
          lift $ V.execApplyT applyState applyCtx $
            mapM V.validateAndApplyTransaction memPoolTxs
      pure $ mkNewMemPool memPool invalidTxs
  where
    mkNewMemPool
      :: MemPool.MemPool
      -> [Tx.InvalidTransaction]
      -> (MemPool.MemPool, ([Tx.Transaction], [Tx.InvalidTransaction]))
    mkNewMemPool oldMemPool itxs =
      let invalidTxs   = flip map itxs $ \(Tx.InvalidTransaction tx _) -> tx
          newMemPool   = MemPool.removeTxs oldMemPool invalidTxs
          txsInMemPool = DL.toList $ MemPool.transactions newMemPool
       in (newMemPool, (txsInMemPool, itxs))

-- | Atomically remove all specified transactions from the MemPool
removeTxsFromMemPool :: MonadBase IO m => [Tx.Transaction] -> NodeT m ()
removeTxsFromMemPool txs  =
  modifyNodeState_ txPool $ \memPool ->
    pure $ MemPool.removeTxs memPool txs

elemTxMemPool :: Tx.Transaction -> MonadBase IO m => NodeT m Bool
elemTxMemPool tx = pure . flip MemPool.elemMemPool tx =<< getTxMemPool

elemTxMemPool' :: MonadBase IO m => H.Hash E.Base16ByteString -> NodeT m Bool
elemTxMemPool' txHash = pure . flip MemPool.elemMemPool' txHash =<< getTxMemPool

isTestNode :: Monad m => NodeT m Bool
isTestNode = testMode <$> askNodeConfig

isValidatingNode :: MonadBase IO m => NodeT m Bool
isValidatingNode = do
  validatorAddrs <- CAP.unValidatorSet <$> getValidatorSet
  selfAddr <- askSelfAddress
  return $ selfAddr `Set.member` validatorAddrs

getValidatorSet :: MonadBase IO m => NodeT m CAP.ValidatorSet
getValidatorSet = do
  lastBlock <- getLastBlock
  let poa = Block.consensus $ Block.header lastBlock
  return $ CAP.validatorSet poa

-- | Returns list of peers that are validating nodes
getValidatorPeers :: MonadBase IO m => NodeT m Peers
getValidatorPeers = do
  peers <- getPeers
  validatorAddrs <- CAP.unValidatorSet <$> getValidatorSet
  return $ flip Set.filter peers $ \peer ->
    peerAccAddr peer `Set.member` validatorAddrs

withApplyCtx :: MonadBase IO m => (V.ApplyCtx -> NodeT m a) -> NodeT m a
withApplyCtx f = do
  latestBlk   <- getLastBlock
  nodeAddress <- askSelfAddress
  nodePrivKey <- askPrivateKey
  f V.ApplyCtx
    { applyCurrBlock   = latestBlk
    , applyNodeAddress = nodeAddress
    , applyNodePrivKey = nodePrivKey
    }

-- | Query transaction status by hash:
--   > if in the mempool            - Pending
--   > if in the invalid tx mempool - Rejected
--   > if in the tx database        - Accepted
--   > if in the invalid tx db      - Rejected
--   > else                         - NonExistent
getTxStatus :: MonadReadDB m => H.Hash E.Base16ByteString -> NodeT m Tx.Status
getTxStatus txHash = do
  inMempool <- elemTxMemPool' txHash
  if inMempool
    then pure Tx.Pending
    else do
      elemInvalidTxPool <- elemInvalidTxPool txHash
      if elemInvalidTxPool
        then pure Tx.Rejected
        else do
          eTx <- lift $ DB.readTransaction txHash
          case eTx of
            Right _  -> pure Tx.Accepted
            Left err -> do
              eItx <- lift $ DB.readInvalidTx txHash
              case eItx of
                Right _  -> pure Tx.Rejected
                Left err -> pure Tx.NonExistent
-------------------------------------------------------------------------------
-- Query Ledger (World) state
-------------------------------------------------------------------------------

lookupInLedger :: MonadBase IO m => (Ledger.World -> a) -> NodeT m a
lookupInLedger f = withLedgerState $ return . f

lookupAccount
  :: MonadBase IO m
  => Address AAccount
  -> NodeT m (Either Ledger.AccountError Account.Account)
lookupAccount = lookupInLedger . Ledger.lookupAccount

-------------------------------------------------------------------------------
-- Sync Ledger State & DB
-------------------------------------------------------------------------------

-- | Critical Error during application of block transactions to ledger state and
-- synchronization of ledger state with the database
data ApplyBlockError
  = InvalidBlock Block.InvalidBlock
  | ErrorSyncingDatabase Text
  deriving Show

verifyValidateAndApplyBlock
  :: (MonadBaseControl IO m, MonadReadWriteDB m)
  => Block.Block
  -> NodeT m (Either ApplyBlockError ())
verifyValidateAndApplyBlock block = do
  currLedgerState <- getLedger
  prevBlock       <- getLastBlock
  -- Verify, validate, and apply with respect to ledger state
  eRes <- withApplyCtx $ \applyCtx -> do
    let applyState = V.initApplyState currLedgerState
    lift $ V.verifyValidateAndApplyBlock applyState applyCtx block
  -- New block should only be applied if 0 errors in block
  case eRes of
    Left err -> pure $ Left $ InvalidBlock err
    Right (newLedgerState, deltasMap) -> do
      -- Update node state with new values
      setLastBlock block
      setLedger newLedgerState
      -- Attempt to sync ledger state with DB
      eSyncRes <- NodeState.syncNodeStateWithDBs
      case eSyncRes of
        Left err -> do
          -- Reset previous block and ledger state on sync db failure
          setLastBlock prevBlock
          setLedger currLedgerState
          pure $ Left $ ErrorSyncingDatabase $ show err
        Right _  -> do
          -- Atomically remove transactions in this block from NodeState mempool
          removeTxsFromMemPool $ Block.transactions block

          let blockIdx = Block.index block
          txLogFile <- askTxLogFilePath
          -- Write Deltas collected during applyBlock to TxLog
          liftBase $ forM_ (Map.toList deltasMap) $ \(addr,deltas) ->
            TxLog.writeDeltas txLogFile (fromIntegral blockIdx) addr deltas

          pure $ Right ()

syncNodeStateWithDBs
  :: (MonadBaseControl IO m, MonadWriteDB m)
  => NodeT m (Either (DBError m) ())
syncNodeStateWithDBs = do
  eRes <- syncWorldWithDBs
  case eRes of
    Left err -> pure $ Left err
    Right _  -> syncLastBlockWithDBs

syncWorldWithDBs :: MonadWriteDB m => NodeT m (Either (DBError m) ())
syncWorldWithDBs = withLedgerState (lift . DB.syncWorld)

-- | Since blocks are not stored in ledger(world) state, we
-- must sync them to the DB separately
syncLastBlockWithDBs
  :: (MonadBaseControl IO m, MonadWriteDB m)
  => NodeT m (Either (DBError m) ())
syncLastBlockWithDBs = do
  lastBlock <- getLastBlock
  lift $ DB.writeBlock lastBlock

-------------------------------------------------------------------------------
-- Load Preallocated Accounts
-------------------------------------------------------------------------------

-- | Loads the validator set from a directory of the form:
--   <Dir of Account dirs>/
--       - <Account Dir 1>/
--           - key                 -- Private Key
--           - key.pub             -- Public Key
--           - account             -- JSON Serialized Account
--       - <Account Dir 2>/
--           - key                 -- Private Key
--           - key.pub             -- Public Key
--           - account             -- JSON Serialized Account
--       ...
--       - <Account Dir N>/
--           - key                 -- Private Key
--           - key.pub             -- Public Key
--           - account             -- JSON Serialized Account

loadPreallocatedAccs :: MonadBase IO m => NodeT m (Either Text [Account.Account])
loadPreallocatedAccs = do
  dir <- preallocated <$> askNodeConfig
  liftBase $ Account.readAccountsFromDir dir

{-# LANGUAGE Rank2Types #-}

module Consensus.Authority (

  ValidationCtx(..),
  BlockValidationError(..),

  validateBlock,
  validateBlockSignatures,

) where

import Protolude

import Control.Monad.Base

import Control.Arrow ((&&&))

import qualified Data.List as List
import qualified Data.Set as Set

import DB
import Address (Address, AAccount)
import NodeState (NodeT)
import qualified Account
import qualified Block
import qualified Key
import qualified Ledger
import qualified NodeState as NS

import Consensus.Authority.Params (ValidatorSet(..), PoA(..))

data BlockValidationError
  = BlockWaitingForSigs Int                         -- ^ Generated block is waiting for sigs, so don't generate another
  | NotEnoughSignatures Int Int                     -- ^ Block does not have enough signatures
  | InvalidBlockPeriod Int64 Int64                  -- ^ When a block has been created too quickly
  | BlockGenLimitSurpassed Int (Address AAccount)   -- ^ When block is generated by a validator within the blockGenLimit
  | BlockSignerLimitSurpassed (Address AAccount)    -- ^ When block contains a signature from a node that has signed a block too recently
  | NonValidatingNodeAddress (Address AAccount)     -- ^ A signature from an account with address that does not belong to a validating node
  | NonValidatingNodeOrigin (Address AAccount)      -- ^ The origin of the block is not a validating node
  | InvalidSignature Key.InvalidSignature           -- ^ When a signature fails to be validated
  | NotEnoughTransactions Int Int                   -- ^ When block doesn't have enough transactions
  | DatabaseReadError Text                          -- ^ When the consensus process fails to read blocks from the DB
  | ValidatorAccountDoesNotExist (Address AAccount) -- ^ Block signer address does not refer to an existing account in the ledger
  | AlreadySignedBlockAtHeight Int                  -- ^ If a validating node has already signed a block at the given height
  | BlockValidationErrors [BlockValidationError]
  deriving (Show, Eq)

-------------------------------------------------------------------------------
-- Validation - PoA Consensus
-------------------------------------------------------------------------------

data ValidationCtx = BeforeAccept | BeforeSigning

-- | Validate a block given a PoAParams (by nodes about to accept the block):
-- Collects errors that occur during validation and reports them.
validateBlock
  :: MonadReadDB m
  => ValidationCtx       -- ^ Validate Signatures?
  -> Block.Block         -- ^ Block to validate
  -> NodeT m (BlockValidationError, Bool)
validateBlock validateCtx newBlock = do
    prevBlock <- NS.getLastBlock
    let prevBlockPoAParams = Block.getConsensus prevBlock
    let vAddrs = Set.toList $ unValidatorSet $ validatorSet prevBlockPoAParams

    -- Verify that block signatures are
    --   1) Properly encoded as ByteStrings
    --   2) Originate from validating nodes priv keys
    (sigErrs, nSigs, signerAddrs) <- do
      let blockSigsAndAddrs = Set.toList $ Block.signatures newBlock
      -- Lookup public keys of validator accounts
      (pubKeyErrs', vPubKeys) <- partitionEithers <$> mapM lookupValidatorPubKey vAddrs
      -- Verify block signatures
      let (blockSigs,signerAddrs) = partitionBlkSigsAndAddrs blockSigsAndAddrs
      (sigErrs, nValidSigs) <- validateBlockSignatures newBlock vAddrs blockSigsAndAddrs
      let allErrs = pubKeyErrs' ++ sigErrs
      return (allErrs, nValidSigs, signerAddrs)

    -- Validate the w/ respect to PoA Consensus params
    isValid <- do
      let blockIdx = Block.index newBlock
      validBlockGenLimit  <- lift $ validateBlockGenLimit prevBlockPoAParams blockIdx
      validBlockSignLimit <- lift $ validateSignerLimit prevBlockPoAParams blockIdx signerAddrs

      pure $ do

        -- If validating before signing, don't check # sigs
        case validateCtx of
          BeforeAccept  -> validateNumSigs prevBlockPoAParams nSigs
          BeforeSigning -> Right ()

        validateMinTxs prevBlockPoAParams
        validateBlockPeriod prevBlockPoAParams prevBlock
        validateOrigin vAddrs
        validBlockGenLimit
        validBlockSignLimit

    case isValid of
      Left err -> do
        let allErrs = BlockValidationErrors $ sigErrs ++ [err]
        pure (allErrs, False)
      Right _  -> pure (BlockValidationErrors sigErrs, True)
  where
    blockOrigin = Block.origin (Block.header newBlock)

    partitionBlkSigsAndAddrs
      :: [Block.BlockSignature]
      -> ([Key.Signature], [Address AAccount])
    partitionBlkSigsAndAddrs blockSigsAndAddrs = unzip $
        map getBlkSigAndAddr blockSigsAndAddrs
      where
        getBlkSigAndAddr = Block.signature &&& Block.signerAddr

    -------------------------------------------------------
    -- PoA Consensus Parameter Validation
    -------------------------------------------------------

    -- Validate origin address corresponds to a validating node account
    validateOrigin addrs
      | blockOrigin `elem` addrs = Right ()
      | otherwise = Left $ NonValidatingNodeOrigin blockOrigin

    -- Validate that a block has enough valid signatures
    validateNumSigs poaParams n
      | n >= threshold poaParams = Right ()
      | otherwise = Left $ NotEnoughSignatures n (threshold poaParams)

    -- Validate that the block contains the minimum # of txs
    validateMinTxs poaParams
      | numTxs >= minTxs poaParams = Right ()
      | otherwise = Left $ NotEnoughTransactions numTxs (minTxs poaParams)
      where
        numTxs = length (Block.transactions newBlock)

    -- Validate that the block's timestamp is valid
    validateBlockPeriod poaParams prevBlock
      | period >= blockPeriod poaParams = Right ()
      | otherwise = Left $ InvalidBlockPeriod period (blockPeriod poaParams)
      where
        period = blockTs - prevBlockTs
        prevBlockTs = Block.timestamp $ Block.header prevBlock
        blockTs = Block.timestamp $ Block.header newBlock

    -- Validate the block gen limit. In practice, `blockGenLimit` should not
    -- surpass # of validators, or consensus will get stuck.
    validateBlockGenLimit
      :: MonadReadDB m
      => PoA
      -> Int
      -> m (Either BlockValidationError ())
    validateBlockGenLimit poaParams blockIdx = do
      let n = blockGenLimit poaParams - 1
      eBlocks <- DB.readLastNBlocks n
      case eBlocks of
        Left err -> pure $ Left $ DatabaseReadError $ show err
        Right blks -> do
          let blockOrigins = map (Block.origin . Block.header) blks
          let currBlkOrigin = Block.origin $ Block.header newBlock
          -- Check if curr block origin is the past n blocks
          case List.findIndex (== currBlkOrigin) blockOrigins of
            Nothing  -> pure $ Right ()
            Just idx -> pure $ Left $
              let blocksNeededToWait = blockGenLimit poaParams - idx + 1
                  blockOrigin = Block.origin $ Block.header newBlock
               in BlockGenLimitSurpassed blocksNeededToWait blockOrigin

    -- Validate that the block signers have not been block signers in the past
    -- `signerLimit` number of blocks. In practice, `signerLimit` should not
    -- surpass (# of validators / # of block signatures required) or consensus
    -- will get stuck.
    validateSignerLimit
      :: MonadReadDB m
      => PoA               -- ^ Previous block PoA Params
      -> Int               -- ^ Current Block index
      -> [Address AAccount] -- ^ Current Block signer addresses
      -> m (Either BlockValidationError ())
    validateSignerLimit poaParams blockIdx currBlkSignerAddrs = do
      let n = signerLimit poaParams - 1
      eBlocks <- DB.readLastNBlocks n
      let eBlockSigners = concatMap (Set.toList . Block.signatures) <$> eBlocks
      case eBlockSigners of
        Left err -> pure $ Left $ DatabaseReadError $ show err
        Right pastNBlockSigAddrs -> do
          let signerAddrs = snd $ partitionBlkSigsAndAddrs pastNBlockSigAddrs
              invalidSigners = List.intersect currBlkSignerAddrs signerAddrs
          case headMay invalidSigners of
            Nothing            -> pure $ Right ()
            Just invalidSigner -> pure $ Left $ BlockSignerLimitSurpassed invalidSigner

-- | Validates block signatures, returning a list of errors that occurred
-- during validation, and the total number of valid block signatures. We do not want to
-- stop validation on the first error because this would give attackers too much
-- control. By collecting errors and still succeeding if enough valid signatures
-- are present, we do not allow an invalid signature to inhibit consensus.
--
-- Note: We must `verify` all block signatures during this validation because an
-- attacker could easily send a `BlockSignature` message with a false address.
-- We must verify the signature corresponds to the validator account
validateBlockSignatures
  :: MonadBase IO m
  => Block.Block                            -- ^ Block to verify
  -> [Address AAccount]                     -- ^ List of Validator Addresses
  -> [Block.BlockSignature]                 -- ^ List of block signatures
  -> NodeT m ([BlockValidationError], Int)  -- ^ (List of errors, Number of valid signatures)
validateBlockSignatures block vAddrs blockSigs =
  fmap (second length . partitionEithers) $
    flip mapM blockSigs $ \(Block.BlockSignature sig addr) ->
      if addr `elem` vAddrs
        then do
          ePubKey <- lookupValidatorPubKey addr
          case ePubKey of
            Left err -> pure $ Left err
            Right pubKey ->
              case Block.verifyBlockSig pubKey sig block of
                Left err -> pure $ Left $ InvalidSignature err
                Right _  -> pure $ Right addr
        else pure $ Left $ NonValidatingNodeAddress addr
  where
    blockHash = Block.hashBlock block

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

lookupValidatorPubKey
  :: MonadBase IO m
  => Address AAccount
  -> NodeT m (Either BlockValidationError Key.PubKey)
lookupValidatorPubKey addr =
  first (const $ ValidatorAccountDoesNotExist addr) <$>
    lookupPubKey addr

-- | Get an account's public key by address from the ledger state
lookupPubKey
  :: MonadBase IO m
  => Address AAccount
  -> NodeT m (Either Ledger.AccountError Key.PubKey)
lookupPubKey addr = do
  mAcc <- NS.lookupAccount addr
  case mAcc of
    Left err -> return $ Left err
    Right acc -> return $ Right $ Account.publicKey acc

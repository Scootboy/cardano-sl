{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- To support actual wallet accounts we listen to applications and rollbacks
-- of blocks, extract transactions from block and extract our
-- accounts (such accounts which we can decrypt).
-- We synchronise wallet-db (acidic-state) with node-db
-- and support last seen tip for each walletset.
-- There are severals cases when we must  synchronise wallet-db and node-db:
-- • When we relaunch wallet. Desynchronization can be caused by interruption
--   during blocks application/rollback at the previous launch,
--   then wallet-db can fall behind from node-db (when interrupted during rollback)
--   or vice versa (when interrupted during application)
--   @syncWSetsWithGStateLock@ implements this functionality.
-- • When a user wants to import a secret key. Then we must rely on
--   Utxo (GStateDB), because blockchain can be large.

module Pos.Wallet.Web.Tracking.Sync
       ( syncWalletsFromGState
       , processSyncResult
       , trackingApplyTxs
       , trackingRollbackTxs
       , applyModifierToWallet
       , rollbackModifierFromWallet
       , BlockLockMode
       , WalletTrackingEnv

       , restoreWalletHistory
       , txMempoolToModifier

       , fixingCachedAccModifier
       , fixCachedAccModifierFor

       , buildTHEntryExtra
       , isTxEntryInteresting

       -- For tests
       , evalChange
       ) where

import           Universum
import           Unsafe (unsafeLast)

import           Control.Exception.Safe (handleAny)
import           Control.Lens (to)
import qualified Data.DList as DL
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as M
import           Ether.Internal (HasLens (..))
import           Formatting (build, sformat, shown, (%))
import           Mockable (Mockable (..))
import           Mockable.Concurrent (Async, async, wait)
import           System.Wlog (HasLoggerName, WithLogger, logError, logInfo, logWarning,
                              modifyLoggerName)

import           Pos.Block.Types (Blund, undoTx)
import           Pos.Client.Txp.History (TxHistoryEntry (..), txHistoryListToMap)
import           Pos.Core (BlockHeaderStub, ChainDifficulty, HasConfiguration, HasDifficulty (..),
                           HeaderHash, Timestamp, blkSecurityParam, genesisHash, headerHash,
                           headerSlotL, timestampToPosix)
import           Pos.Core.Block (BlockHeader, getBlockHeader, mainBlockTxPayload)
import           Pos.Core.Txp (TxAux (..), TxOutAux (..), TxUndo, toaOut, txOutAddress)
import           Pos.Crypto (EncryptedSecretKey, WithHash (..), shortHashF, withHash)
import           Pos.DB.Block (getBlund)
import qualified Pos.DB.Block.Load as GS
import qualified Pos.DB.BlockIndex as DB
import           Pos.DB.Class (MonadDBRead (..))
import qualified Pos.GState as GS
import           Pos.GState.BlockExtra (foldlUpWhileM, resolveForwardLink)
import           Pos.Slotting (MonadSlots (..), MonadSlotsData, getSlotStartPure, getSystemStartM)
import           Pos.StateLock (Priority (..), StateLock, withStateLockNoMetrics)
import           Pos.Txp (MonadTxpMem, flattenTxPayload, genesisUtxo, getLocalTxsNUndo, topsortTxs,
                          unGenesisUtxo, _txOutputs)
import           Pos.Util.Chrono (getNewestFirst)
import           Pos.Util.LogSafe (logErrorS, logInfoS, logWarningS)
import qualified Pos.Util.Modifier as MM
import           Pos.Util.Servant (encodeCType)
import           Pos.Util.Util (getKeys)

import           Pos.Wallet.WalletMode (WalletMempoolExt)
import           Pos.Wallet.Web.Account (MonadKeySearch (..))
import           Pos.Wallet.Web.ClientTypes (Addr, CId, CTxMeta (..), CWAddressMeta (..), Wal,
                                             addrMetaToAccount)
import           Pos.Wallet.Web.Error.Types (WalletError (..))
import           Pos.Wallet.Web.Pending.Types (PtxBlockInfo,
                                               PtxCondition (PtxApplying, PtxInNewestBlocks))
import           Pos.Wallet.Web.State (CustomAddressType (..), MonadWalletDB, WalletTip (..))
import qualified Pos.Wallet.Web.State as WS
import           Pos.Wallet.Web.Tracking.Decrypt (THEntryExtra (..), WalletDecrCredentials,
                                                  buildTHEntryExtra, eskToWalletDecrCredentials,
                                                  isTxEntryInteresting, selectOwnAddresses)
import           Pos.Wallet.Web.Tracking.Modifier (CAccModifier (..), CachedCAccModifier,
                                                   VoidModifier, deleteAndInsertIMM,
                                                   deleteAndInsertMM, deleteAndInsertVM,
                                                   indexedDeletions, sortedInsertions)

type BlockLockMode ctx m =
     ( WithLogger m
     , MonadDBRead m
     , MonadReader ctx m
     , HasLens StateLock ctx StateLock
     , MonadMask m
     )

type WalletTrackingEnvRead ctx m =
     ( BlockLockMode ctx m
     , MonadTxpMem WalletMempoolExt ctx m
     , WS.MonadWalletDBRead ctx m
     , MonadSlotsData ctx m
     , WithLogger m
     , HasConfiguration
     )

type WalletTrackingEnv ctx m =
     ( WalletTrackingEnvRead ctx m
     , MonadWalletDB ctx m
     )

-- | Restore the full history for a wallet, given its 'EncryptedSecretKey'
-- TODO(adn): Periodically update the progress in the wallet state.
-- TODO(adn): Make it async.
restoreWalletHistory :: ( Mockable Async m
                         , MonadWalletDB ctx m
                         , MonadDBRead m
                         , WithLogger m
                         , HasLens StateLock ctx StateLock
                         , MonadMask m
                         , MonadSlotsData ctx m
                         ) => EncryptedSecretKey -> m ()
restoreWalletHistory encSK = do
    res <- wait =<< async (syncWalletsFromGState [encSK])
    mapM_ processSyncResult res

txMempoolToModifier :: WalletTrackingEnvRead ctx m => WalletDecrCredentials -> m CAccModifier
txMempoolToModifier credentials = do
    let wHash (i, TxAux {..}, _) = WithHash taTx i
        getDiff       = const Nothing  -- no difficulty (mempool txs)
        getTs         = const Nothing  -- don't give any timestamp
        getPtxBlkInfo = const Nothing  -- no slot of containing block
    (txs, undoMap) <- getLocalTxsNUndo

    txsWUndo <- forM txs $ \(id, tx) -> case HM.lookup id undoMap of
        Just undo -> pure (id, tx, undo)
        Nothing -> do
            let errMsg = sformat ("There is no undo corresponding to TxId #"%build%" from txp mempool") id
            logError errMsg
            throwM $ InternalError errMsg

    case topsortTxs wHash txsWUndo of
        Nothing      -> mempty <$ logWarning "txMempoolToModifier: couldn't topsort mempool txs"
        Just ordered -> do
            tipH <- DB.getTipHeader
            dbUsed <- WS.getCustomAddresses WS.UsedAddr
            pure $
                trackingApplyTxs credentials dbUsed getDiff getTs getPtxBlkInfo $
                map (\(_, tx, undo) -> (tx, undo, tipH)) ordered

----------------------------------------------------------------------------
-- Logic
----------------------------------------------------------------------------

data SyncResult = SyncSucceeded
                -- ^ The sync succeed without errors.
                | NoSyncTipAvailable (CId Wal)
                -- ^ There was no sync tip available for this wallet.
                | NotSyncable (CId Wal) WalletError
                -- ^ The given wallet cannot be synced due to an unexpected error.
                -- The routine was not even started.
                | SyncFailed  (CId Wal) SomeException
                -- ^ The sync process failed abruptly during the sync process.

-- | TODO(adn): Process the exceptions rather than just logging them.
processSyncResult :: ( WithLogger m
                     , MonadThrow m
                     , MonadIO m
                     ) => SyncResult -> m ()
processSyncResult sr = case sr of
    SyncSucceeded -> return ()
    NoSyncTipAvailable walletId ->
        logWarningS $ sformat ("There is no syncTip corresponding to wallet #" % build) walletId
    NotSyncable walletId walletError -> do
        logErrorS $ sformat ("Wallet #" % build % " is not syncable. Error was: " % shown) walletId walletError
    SyncFailed  walletId exception -> do
        let errMsg  = "Sync failed for Wallet #" % build % ". An exception was raised during the sync process: " % shown
        logErrorS $ sformat errMsg walletId exception

-- | Iterates over blocks (using forward links) and reconstructs the transaction
-- history for the given wallets.
syncWalletsFromGState
    :: forall ctx m.
    ( MonadWalletDB ctx m
    , BlockLockMode ctx m
    , MonadSlotsData ctx m
    , HasConfiguration
    )
    => [EncryptedSecretKey] -> m [SyncResult]
syncWalletsFromGState encSKs = processEncryptedKeys encSKs []
  where
    processEncryptedKeys :: [EncryptedSecretKey] -> [SyncResult] -> m [SyncResult]
    processEncryptedKeys [] !aux = pure aux
    processEncryptedKeys (encSK : rest) !aux = do
        let credentials@(_, walletId) = eskToWalletDecrCredentials encSK
        let onError ex = processEncryptedKeys rest (SyncFailed walletId ex : aux)
        handleAny onError $ do
            WS.getWalletSyncTip walletId >>= \case
                Nothing                -> processEncryptedKeys rest (NoSyncTipAvailable walletId : aux)
                Just NotSynced         -> do
                    res <- syncDo credentials Nothing
                    processEncryptedKeys rest (res : aux)
                Just (SyncedWith wTip) -> DB.getHeader wTip >>= \case
                    Nothing ->
                        let err = InternalError $
                                  sformat ("Couldn't get block header of wallet by last synced hh: "%build) wTip
                        in processEncryptedKeys rest (NotSyncable walletId err : aux)
                    Just wHeader -> do
                        res <- syncDo credentials (Just wHeader)
                        processEncryptedKeys rest (res : aux)

    syncDo :: WalletDecrCredentials -> Maybe BlockHeader -> m SyncResult
    syncDo credentials wTipH = do
        let wdiff = maybe (0::Word32) (fromIntegral . ( ^. difficultyL)) wTipH
        gstateTipH <- DB.getTipHeader
        -- If account's syncTip is before the current gstate's tip,
        -- then it loads accounts and addresses starting with @wHeader@.
        -- syncTip can be before gstate's the current tip
        -- when we call @syncWalletSetWithTip@ at the first time
        -- or if the application was interrupted during rollback.
        -- We don't load all blocks explicitly, because blockain can be long.
        (syncResult, wNewTip) <-
            if (gstateTipH ^. difficultyL > fromIntegral blkSecurityParam + fromIntegral wdiff) then do
                -- Wallet tip is "far" from gState tip,
                -- rollback can't occur more then @blkSecurityParam@ blocks,
                -- so we can sync wallet and GState without the block lock
                -- to avoid blocking of blocks verification/application.
                bh <- unsafeLast . getNewestFirst <$> GS.loadHeadersByDepth (blkSecurityParam + 1) (headerHash gstateTipH)
                logInfo $
                    sformat ("Wallet's tip is far from GState tip. Syncing with "%build%" without the block lock")
                    (headerHash bh)
                result <- syncHistoryWithGStateUnsafe credentials wTipH bh
                pure $ (Just result, Just bh)
            else pure (Nothing, wTipH)

        let finaliseSyncUnderBlockLock = withStateLockNoMetrics HighPriority $ \tip -> do
                logInfo $ sformat ("Syncing wallet with "%build%" under the block lock") tip
                tipH <- maybe (error "No block header corresponding to tip") pure =<< DB.getHeader tip
                syncHistoryWithGStateUnsafe credentials wNewTip tipH

        case syncResult of
            Nothing            -> finaliseSyncUnderBlockLock
            Just SyncSucceeded -> finaliseSyncUnderBlockLock
            Just failedSync    -> pure failedSync

----------------------------------------------------------------------------
-- Unsafe operations. Core logic.
----------------------------------------------------------------------------
-- These operation aren't atomic and don't take the block lock.

-- BE CAREFUL! This function iterates over blockchain, the blockchain can be large.
syncHistoryWithGStateUnsafe
    :: forall ctx m .
    ( MonadWalletDB ctx m
    , MonadDBRead m
    , WithLogger m
    , MonadSlotsData ctx m
    , HasConfiguration
    )
    => WalletDecrCredentials
    -> Maybe BlockHeader       -- ^ Block header corresponding to wallet's tip.
                               --   Nothing when wallet's tip is genesisHash
    -> BlockHeader             -- ^ GState header hash
    -> m SyncResult
syncHistoryWithGStateUnsafe credentials@(_, walletId) wTipHeader gstateH = setLogger $ do
    systemStart  <- getSystemStartM
    slottingData <- GS.getSlottingData

    let diff = (^. difficultyL)
        mDiff = Just . diff
        gbTxs = either (const []) (^. mainBlockTxPayload . to flattenTxPayload)

        mainBlkHeaderTs mBlkH =
          getSlotStartPure systemStart (mBlkH ^. headerSlotL) slottingData
        blkHeaderTs = either (const Nothing) mainBlkHeaderTs

        -- assuming that transactions are not created until syncing is complete
        ptxBlkInfo = const Nothing

        rollbackBlock :: [(CId Addr, HeaderHash)] -> Blund -> CAccModifier
        rollbackBlock dbUsed (b, u) =
            trackingRollbackTxs credentials dbUsed mDiff blkHeaderTs $
            zip3 (gbTxs b) (undoTx u) (repeat $ getBlockHeader b)

        applyBlock :: [(CId Addr, HeaderHash)] -> Blund -> m CAccModifier
        applyBlock dbUsed (b, u) = pure $
            trackingApplyTxs credentials dbUsed mDiff blkHeaderTs ptxBlkInfo $
            zip3 (gbTxs b) (undoTx u) (repeat $ getBlockHeader b)

        computeAccModifier :: BlockHeader -> m CAccModifier
        computeAccModifier wHeader = do
            dbUsed <- WS.getCustomAddresses WS.UsedAddr
            logInfoS $
                sformat ("Wallet "%build%" header: "%build%", current tip header: "%build)
                walletId wHeader gstateH
            if | diff gstateH > diff wHeader -> do
                     let loadCond (b,_undo) _ = b ^. difficultyL <= gstateH ^. difficultyL
                         convertFoo rr blund = (rr <>) <$> applyBlock dbUsed blund
                     -- If wallet's syncTip is before than the current tip in the blockchain,
                     -- then it loads wallets starting with @wHeader@.
                     -- Sync tip can be before the current tip
                     -- when we call @syncWalletSetWithTip@ at the first time
                     -- or if the application was interrupted during rollback.
                     -- We don't load blocks explicitly, because blockain can be long.
                     maybe (pure mempty)
                         (\wNextH ->
                            foldlUpWhileM getBlund
                                          wNextH
                                          loadCond
                                          convertFoo
                                          mempty)
                         =<< resolveForwardLink wHeader
               | diff gstateH < diff wHeader -> do
                     -- This rollback can occur
                     -- if the application was interrupted during blocks application.
                     blunds <- getNewestFirst <$>
                         GS.loadBlundsWhile (\b -> getBlockHeader b /= gstateH) (headerHash wHeader)
                     pure $ foldl' (\r b -> r <> rollbackBlock dbUsed b) mempty blunds
               | otherwise -> mempty <$ logInfoS (sformat ("Wallet "%build%" is already synced") walletId)

    whenNothing_ wTipHeader $ do
        let ownGenesisData =
                selectOwnAddresses credentials (txOutAddress . toaOut . snd) $
                M.toList $ unGenesisUtxo genesisUtxo
            ownGenesisAddrs = map snd ownGenesisData
        mapM_ WS.addWAddress ownGenesisAddrs

    startFromH <- maybe firstGenesisHeader pure wTipHeader
    mapModifier@CAccModifier{..} <- computeAccModifier startFromH
    applyModifierToWallet walletId (headerHash gstateH) mapModifier
    logInfoS $
        sformat ("Wallet "%build%" has been synced with tip "
                %shortHashF%", "%build)
                walletId (maybe genesisHash headerHash wTipHeader) mapModifier
    pure SyncSucceeded
  where
    firstGenesisHeader :: m BlockHeader
    firstGenesisHeader = resolveForwardLink (genesisHash @BlockHeaderStub) >>=
        maybe (error "Unexpected state: genesisHash doesn't have forward link")
            (maybe (error "No genesis block corresponding to header hash") pure <=< DB.getHeader)

constructAllUsed
    :: [(CId Addr, HeaderHash)]
    -> VoidModifier (CId Addr, HeaderHash)
    -> HashSet (CId Addr)
constructAllUsed dbUsed modif =
    HS.map fst $
    getKeys $
    MM.modifyHashMap modif $
    HM.fromList $
    zip dbUsed (repeat ()) -- not so good performance :(

-- Process transactions on block application,
-- decrypt our addresses, and add/delete them to/from wallet-db.
-- Addresses are used in TxIn's will be deleted,
-- in TxOut's will be added.
trackingApplyTxs
    :: HasConfiguration
    => WalletDecrCredentials
    -> [(CId Addr, HeaderHash)]               -- ^ All used addresses from db along with their HeaderHashes
    -> (BlockHeader -> Maybe ChainDifficulty) -- ^ Function to determine tx chain difficulty
    -> (BlockHeader -> Maybe Timestamp)       -- ^ Function to determine tx timestamp in history
    -> (BlockHeader -> Maybe PtxBlockInfo)    -- ^ Function to determine pending tx's block info
    -> [(TxAux, TxUndo, BlockHeader)]         -- ^ Txs of blocks and corresponding header hash
    -> CAccModifier
trackingApplyTxs credentials dbUsed getDiff getTs getPtxBlkInfo txs =
    foldl' applyTx mempty txs
  where
    applyTx :: CAccModifier -> (TxAux, TxUndo, BlockHeader) -> CAccModifier
    applyTx CAccModifier{..} (tx, undo, blkHeader) = do
        let hh = headerHash blkHeader
            hhs = repeat hh
            wh@(WithHash _ txId) = withHash (taTx tx)
        let thee@THEntryExtra{..} =
                buildTHEntryExtra credentials (wh, undo) (getDiff blkHeader, getTs blkHeader)

            ownTxIns = map (fst . fst) theeInputs
            ownTxOuts = map fst theeOutputs

            addedHistory = maybe camAddedHistory (flip DL.cons camAddedHistory) (isTxEntryInteresting thee)

            usedAddrs = map (cwamId . snd) theeOutputs
            changeAddrs = evalChange
                              (constructAllUsed dbUsed camUsed)
                              (map snd theeInputs)
                              (map snd theeOutputs)
                              (length theeOutputs == NE.length (_txOutputs $ taTx tx))

            mPtxBlkInfo = getPtxBlkInfo blkHeader
            addedPtxCandidates =
                if | Just ptxBlkInfo <- mPtxBlkInfo
                     -> DL.cons (txId, ptxBlkInfo) camAddedPtxCandidates
                   | otherwise
                     -> camAddedPtxCandidates
        CAccModifier
            (deleteAndInsertIMM [] (map snd theeOutputs) camAddresses)
            (deleteAndInsertVM [] (zip usedAddrs hhs) camUsed)
            (deleteAndInsertVM [] (zip changeAddrs hhs) camChange)
            (deleteAndInsertMM ownTxIns ownTxOuts camUtxo)
            addedHistory
            camDeletedHistory
            addedPtxCandidates
            camDeletedPtxCandidates

-- Process transactions on block rollback.
-- Like @trackingApplyTxs@, but vise versa.
trackingRollbackTxs
    :: HasConfiguration
    => WalletDecrCredentials
    -> [(CId Addr, HeaderHash)]                -- ^ All used addresses from db along with their HeaderHashes
    -> (BlockHeader -> Maybe ChainDifficulty)  -- ^ Function to determine tx chain difficulty
    -> (BlockHeader -> Maybe Timestamp)        -- ^ Function to determine tx timestamp in history
    -> [(TxAux, TxUndo, BlockHeader)]          -- ^ Txs of blocks and corresponding header hash
    -> CAccModifier
trackingRollbackTxs credentials dbUsed getDiff getTs txs =
    foldl' rollbackTx mempty txs
  where
    rollbackTx :: CAccModifier -> (TxAux, TxUndo, BlockHeader) -> CAccModifier
    rollbackTx CAccModifier{..} (tx, undo, blkHeader) = do
        let wh@(WithHash _ txId) = withHash (taTx tx)
            hh = headerHash blkHeader
            hhs = repeat hh
            thee@THEntryExtra{..} =
                buildTHEntryExtra credentials (wh, undo) (getDiff blkHeader, getTs blkHeader)

            ownTxOutIns = map (fst . fst) theeOutputs
            deletedHistory = maybe camDeletedHistory (DL.snoc camDeletedHistory) (isTxEntryInteresting thee)
            deletedPtxCandidates = DL.cons (txId, theeTxEntry) camDeletedPtxCandidates

        -- Rollback isn't needed, because we don't use @utxoGet@
        -- (undo contains all required information)
        let usedAddrs = map (cwamId . snd) theeOutputs
            changeAddrs =
                evalChange
                    (constructAllUsed dbUsed camUsed)
                    (map snd theeInputs)
                    (map snd theeOutputs)
                    (length theeOutputs == NE.length (_txOutputs $ taTx tx))
        CAccModifier
            (deleteAndInsertIMM (map snd theeOutputs) [] camAddresses)
            (deleteAndInsertVM (zip usedAddrs hhs) [] camUsed)
            (deleteAndInsertVM (zip changeAddrs hhs) [] camChange)
            (deleteAndInsertMM ownTxOutIns (map fst theeInputs) camUtxo)
            camAddedHistory
            deletedHistory
            camAddedPtxCandidates
            deletedPtxCandidates

applyModifierToWallet
    :: MonadWalletDB ctx m
    => CId Wal
    -> HeaderHash
    -> CAccModifier
    -> m ()
applyModifierToWallet wid newTip CAccModifier{..} = do
    -- TODO maybe do it as one acid-state transaction.
    mapM_ WS.addWAddress (sortedInsertions camAddresses)
    mapM_ (WS.addCustomAddress UsedAddr . fst) (MM.insertions camUsed)
    mapM_ (WS.addCustomAddress ChangeAddr . fst) (MM.insertions camChange)
    WS.updateWalletBalancesAndUtxo camUtxo
    let cMetas = M.fromList
               $ mapMaybe (\THEntry {..} -> (\mts -> (_thTxId, CTxMeta . timestampToPosix $ mts)) <$> _thTimestamp)
               $ DL.toList camAddedHistory
    WS.addOnlyNewTxMetas wid cMetas
    let addedHistory = txHistoryListToMap $ DL.toList camAddedHistory
    WS.insertIntoHistoryCache wid addedHistory
    -- resubmitting worker can change ptx in db nonatomically, but
    -- tracker has priority over the resubmiter, thus do not use CAS here
    forM_ camAddedPtxCandidates $ \(txid, ptxBlkInfo) ->
        WS.setPtxCondition wid txid (PtxInNewestBlocks ptxBlkInfo)
    WS.setWalletSyncTip wid newTip

rollbackModifierFromWallet
    :: (MonadWalletDB ctx m, MonadSlots ctx m)
    => CId Wal
    -> HeaderHash
    -> CAccModifier
    -> m ()
rollbackModifierFromWallet wid newTip CAccModifier{..} = do
    -- TODO maybe do it as one acid-state transaction.
    mapM_ WS.removeWAddress (indexedDeletions camAddresses)
    mapM_ (WS.removeCustomAddress UsedAddr) (MM.deletions camUsed)
    mapM_ (WS.removeCustomAddress ChangeAddr) (MM.deletions camChange)
    WS.updateWalletBalancesAndUtxo camUtxo
    forM_ camDeletedPtxCandidates $ \(txid, poolInfo) -> do
        curSlot <- getCurrentSlotInaccurate
        WS.ptxUpdateMeta wid txid (WS.PtxResetSubmitTiming curSlot)
        WS.setPtxCondition wid txid (PtxApplying poolInfo)
        let deletedHistory = txHistoryListToMap (DL.toList camDeletedHistory)
        WS.removeFromHistoryCache wid deletedHistory
        WS.removeWalletTxMetas wid (map encodeCType $ M.keys deletedHistory)
    WS.setWalletSyncTip wid newTip

-- Change address is an address which money remainder is sent to.
-- We will consider output address as "change" if:
-- 1. it belongs to source account (taken from one of source addresses)
-- 2. it's not mentioned in the blockchain (aka isn't "used" address)
-- 3. there is at least one non "change" address among all outputs ones

-- The first point is very intuitive and needed for case when we
-- send tx to somebody, i.e. to not our address.
-- The second point is needed for case when
-- we send a tx from our account to the same account.
-- The third point is needed for case when we just created address
-- in an account and then send a tx from the address belonging to this account
-- to the created.
-- In this case both output addresses will be treated as "change"
-- by the first two rules.
-- But the third rule will make them not "change".
-- This decision is controversial, but we can't understand from the blockchain
-- which of them is really "change".
-- There is an option to treat both of them as "change", but it seems to be more puzzling.
evalChange
    :: HashSet (CId Addr)
    -> [CWAddressMeta] -- ^ Own input addresses of tx
    -> [CWAddressMeta] -- ^ Own outputs addresses of tx
    -> Bool            -- ^ Whether all tx's outputs are our own
    -> [CId Addr]
evalChange allUsed inputs outputs allOutputsOur
    | [] <- inputs = [] -- It means this transaction isn't our outgoing transaction.
    | inp : _ <- inputs =
        let srcAccount = addrMetaToAccount inp in
        -- Apply the first point.
        let addrFromSrcAccount = HS.fromList $ map cwamId $ filter ((== srcAccount) . addrMetaToAccount) outputs in
        -- Apply the second point.
        let potentialChange = addrFromSrcAccount `HS.difference` allUsed in
        -- Apply the third point.
        if allOutputsOur && potentialChange == HS.fromList (map cwamId outputs) then []
        else HS.toList potentialChange

setLogger :: HasLoggerName m => m a -> m a
setLogger = modifyLoggerName (<> "wallet" <> "sync")

----------------------------------------------------------------------------
-- Cached modifier
----------------------------------------------------------------------------

-- | Evaluates `txMempoolToModifier` and provides result as a parameter
-- to given function.
fixingCachedAccModifier
    :: (WalletTrackingEnvRead ctx m, MonadKeySearch key m)
    => (CachedCAccModifier -> key -> m a)
    -> key -> m a
fixingCachedAccModifier action key =
    findKey key >>= \encSK -> txMempoolToModifier (eskToWalletDecrCredentials encSK) >>= flip action key

fixCachedAccModifierFor
    :: (WalletTrackingEnvRead ctx m, MonadKeySearch key m)
    => key
    -> (CachedCAccModifier -> m a)
    -> m a
fixCachedAccModifierFor key action =
    fixingCachedAccModifier (const . action) key

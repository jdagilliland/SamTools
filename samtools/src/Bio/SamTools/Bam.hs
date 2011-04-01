{-# LANGUAGE ForeignFunctionInterface #-}

-- | This module provides a fairly direct representation of the
-- SAM/BAM alignment format, along with an interface to read and write
-- alignments in this format.
-- 
-- The package is based on the C SamTools library available at
-- 
-- <http://samtools.sourceforge.net/>
-- 
-- and the SAM/BAM file format is described here
-- 
-- <http://samtools.sourceforge.net/SAM-1.3.pdf>
-- 
-- This package only reads existing alignment files generated by other
-- tools. The meaning of the various flags is actually determined by
-- the program that produced the alignment file.

module Bio.SamTools.Bam ( 
  -- * Target sequence sets
  HeaderSeq(..)
  , Header, nTargets, targetSeqList, targetSeq, targetSeqName, targetSeqLen, lookupTarget
  
  -- * SAM/BAM format alignments
  , Bam1
  , targetID, targetName, targetLen, position
  , isPaired, isProperPair, isUnmap, isMateUnmap, isReverse, isMateReverse
  , isRead1, isRead2, isSecondary, isQCFail, isDup
  , cigars, queryName, queryLength, querySeq
  , mateTargetID, mateTargetName, mateTargetLen, matePosition, insertSize
    
  , nMismatch, nHits, matchDesc                                                               
                                                               
  , refSpLoc, refSeqLoc
                      
  -- * Reading SAM/BAM format files
  , InHandle, inHeader
  , openTamInFile, openTamInFileWithIndex, openBamInFile
  , closeInHandle
  , withTamInFile, withTamInFileWithIndex, withBamInFile
  , get1
  -- * Writing SAM/BAM format files
  , OutHandle, outHeader
  , openTamOutFile, openBamOutFile
  , closeOutHandle
  , withTamOutFile, withBamOutFile
  , put1
  )
       where

import Control.Concurrent.MVar
import Control.Exception
import Control.Monad
import Data.Bits
import qualified Data.ByteString.Char8 as BS
import Foreign hiding (new)
import Foreign.C.Types
import Foreign.C.String

import qualified Data.Vector as V

import Bio.SeqLoc.OnSeq
import qualified Bio.SeqLoc.SpliceLocation as SpLoc
import Bio.SeqLoc.Strand

import Bio.SamTools.Cigar
import Bio.SamTools.Internal
import Bio.SamTools.LowLevel

-- | 'Just' the reference target sequence ID in the target set, or
-- 'Nothing' for an unmapped read
targetID :: Bam1 -> Maybe Int
targetID b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ liftM fromTID . getTID
  where fromTID ctid | ctid < 0 = Nothing
                     | otherwise = Just $! fromIntegral ctid

-- | 'Just' the target sequence name, or 'Nothing' for an unmapped
-- read
targetName :: Bam1 -> Maybe BS.ByteString
targetName b = liftM (targetSeqName (header b)) $! targetID b

-- | 'Just' the total length of the target sequence, or 'Nothing' for
-- an unmapped read
targetLen :: Bam1 -> Maybe Int64
targetLen b = liftM (targetSeqLen (header b)) $! targetID b

-- | 'Just' the 0-based index of the leftmost aligned position on the
-- target sequence, or 'Nothing' for an unmapped read
position :: Bam1 -> Maybe Int64
position b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ liftM fromPos . getPos
  where fromPos cpos | cpos < 0 = Nothing
                     | otherwise = Just $! fromIntegral cpos

isFlagSet :: BamFlag -> Bam1 -> Bool
isFlagSet f b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ liftM isfset . getFlag
  where isfset = (== f) . (.&. f)

-- | Is the read paired
isPaired :: Bam1 -> Bool
isPaired = isFlagSet flagPaired

-- | Is the pair properly aligned (usually based on relative orientation and distance)
isProperPair :: Bam1 -> Bool
isProperPair = isFlagSet flagProperPair

-- | Is the read unmapped
isUnmap :: Bam1 -> Bool
isUnmap = isFlagSet flagUnmap

-- | Is the read paired and the mate unmapped
isMateUnmap :: Bam1 -> Bool
isMateUnmap = isFlagSet flagMUnmap

-- | Is the fragment's reverse complement aligned to the target
isReverse :: Bam1 -> Bool
isReverse = isFlagSet flagReverse

-- | Is the read paired and the mate's reverse complement aligned to the target
isMateReverse :: Bam1 -> Bool
isMateReverse = isFlagSet flagMReverse

-- | Is the fragment from the first read in the template
isRead1 :: Bam1 -> Bool
isRead1 = isFlagSet flagRead1

-- | Is the fragment from the second read in the template
isRead2 :: Bam1 -> Bool
isRead2 = isFlagSet flagRead2

-- | Is the fragment alignment secondary
isSecondary :: Bam1 -> Bool
isSecondary = isFlagSet flagSecondary

-- | Did the read fail quality controls
isQCFail :: Bam1 -> Bool
isQCFail = isFlagSet flagQCFail

-- | Is the read a technical duplicate
isDup :: Bam1 -> Bool
isDup = isFlagSet flagDup

-- | CIGAR description of the alignment
cigars :: Bam1 -> [Cigar]
cigars b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ \p -> do
  nc <- getNCigar p
  liftM (map toCigar) $! peekArray nc . bam1Cigar $ p

-- | Name of the query sequence
queryName :: Bam1 -> BS.ByteString
queryName b = unsafePerformIO $ withForeignPtr (ptrBam1 b) (return . bam1QName)

-- | 'Just' the length of the query sequence, or 'Nothing' when it is
-- unavailable.
queryLength :: Bam1 -> Maybe Int64
queryLength b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ liftM fromc . getLQSeq
  where fromc clq | clq < 1 = Nothing
                  | otherwise = Just $! fromIntegral clq

-- | 'Just' the query sequence, or 'Nothing' when it is unavailable
querySeq :: Bam1 -> Maybe BS.ByteString
querySeq b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ \p -> 
  let seqarr = bam1Seq p
      getQSeq l | l < 1 = return Nothing
                | otherwise = return $! Just $! 
                              BS.pack [ seqiToChar . bam1Seqi seqarr $ i | i <- [0..((fromIntegral l)-1)] ]
  in getLQSeq p >>= getQSeq
     
seqiToChar :: CUChar -> Char
seqiToChar = (chars V.!) . fromIntegral
  where chars = emptyChars V.// [(1, 'A'), (2, 'C'), (4, 'G'), (8, 'T'), (15, 'N')]
        emptyChars = V.generate 16 (\idx -> error $ "Unknown char " ++ show idx)

-- | 'Just' the target ID of the mate alignment target reference
-- sequence, or 'Nothing' when the mate is unmapped or the read is
-- unpaired.
mateTargetID :: Bam1 -> Maybe Int
mateTargetID b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ liftM fromTID . getMTID
  where fromTID ctid | ctid < 0 = Nothing
                     | otherwise = Just $! fromIntegral ctid

-- | 'Just' the name of the mate alignment target reference sequence,
-- or 'Nothing' when the mate is unmapped or the read is unpaired.
mateTargetName :: Bam1 -> Maybe BS.ByteString
mateTargetName b = liftM (targetSeqName (header b)) $! mateTargetID b

-- | 'Just' the length of the mate alignment target reference
-- sequence, or 'Nothing' when the mate is unmapped or the read is
-- unpaired.
mateTargetLen :: Bam1 -> Maybe Int64
mateTargetLen b = liftM (targetSeqLen (header b)) $! mateTargetID b

-- | 'Just the 0-based coordinate of the left-most position in the
-- mate alignment on the target, or 'Nothing' when the read is
-- unpaired or the mate is unmapped.
matePosition :: Bam1 -> Maybe Int64
matePosition b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ liftM fromPos . getMPos
  where fromPos cpos | cpos < 0  = Nothing
                     | otherwise = Just $! fromIntegral cpos

-- | 'Just' the total insert length, or 'Nothing' when the length is
-- unavailable, e.g. because the read is unpaired or the mated read
-- pair do not align in the proper relative orientation on the same
-- strand.
insertSize :: Bam1 -> Maybe Int64
insertSize b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ liftM fromISize . getISize
  where fromISize cis | cis < 1 = Nothing
                      | otherwise = Just $! fromIntegral cis

-- | 'Just' the match descriptor alignment field, or 'Nothing' when it
-- is absent
matchDesc :: Bam1 -> Maybe BS.ByteString
matchDesc b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ \p ->
  withCAString "MD" $ \mdstr -> 
  do md <- bamAuxGet p mdstr
     if md == nullPtr
        then return Nothing
        else do cstr <- bamAux2Z md
                if cstr == nullPtr
                   then return Nothing
                   else liftM Just . BS.packCString $ cstr

-- | 'Just' the number of reported alignments, or 'Nothing' when this
-- information is not present.
nHits :: Bam1 -> Maybe Int
nHits b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ \p ->
  withCAString "NH" $ \nhstr ->
  do nh <- bamAuxGet p nhstr
     if nh == nullPtr
        then return Nothing
        else liftM Just $! liftM fromIntegral $! bamAux2i nh

-- | 'Just' the number of mismatches in the alignemnt, or 'Nothing'
-- when this information is not present
nMismatch :: Bam1 -> Maybe Int
nMismatch b = unsafePerformIO $ withForeignPtr (ptrBam1 b) $ \p ->
  withCAString "NM" $ \nmstr ->
  do nm <- bamAuxGet p nmstr
     if nm == nullPtr
        then return Nothing
        else liftM Just $! liftM fromIntegral $! bamAux2i nm

-- | 'Just' the reference sequence location covered by the
-- alignment. This includes nucleotide positions that are reported to
-- be deleted in the read, but not skipped nucleotide position
-- (typically intronic positions in a spliced alignment). If the
-- reference location is unavailable, e.g. for an unmapped read or for
-- a read with no CIGAR format alignment information, then 'Nothing'.
refSpLoc :: Bam1 -> Maybe SpLoc.SpliceLoc
refSpLoc b | isUnmap b = Nothing
           | otherwise = liftM (stranded strand) $! liftM2 (cigarToSpLoc) (position b) (Just . cigars $ b)
             where strand = if isReverse b then RevCompl else Fwd
               
-- | 'Just' the reference sequence location (as per 'refSpLoc') on
-- the target reference (as per 'targetName')
refSeqLoc :: Bam1 -> Maybe SpliceSeqLoc
refSeqLoc b = liftM2 OnSeq (liftM SeqName $! targetName b) (refSpLoc b)

-- | Handle for reading SAM/BAM format alignments
data InHandle = InHandle { inFilename :: !FilePath
                         , samfile :: !(MVar (Ptr SamFileInt))
                         , inHeader :: !Header -- ^ Target sequence set for the alignments
                         }
               
newInHandle :: FilePath -> Ptr SamFileInt -> IO InHandle
newInHandle filename fsam = do
  when (fsam == nullPtr) $ ioError . userError $ "Error opening BAM file " ++ show filename
  mv <- newMVar fsam
  addMVarFinalizer mv (finalizeSamFile mv)
  bhdr <- getSbamHeader fsam
  when (bhdr == nullPtr) $ ioError . userError $ 
    "Error reading header from BAM file " ++ show filename
  hdr <- newHeader bhdr
  return $ InHandle { inFilename = filename, samfile = mv, inHeader = hdr }  

-- | Open a TAM (tab-delimited text) format file with @\@SQ@ headers
-- for the target sequence set.
openTamInFile :: FilePath -> IO InHandle
openTamInFile filename = sbamOpen filename "r" nullPtr >>= newInHandle filename
  
-- | Open a TAM format file with a separate target sequence set index
openTamInFileWithIndex :: FilePath -> FilePath -> IO InHandle
openTamInFileWithIndex filename indexname 
  = withCString indexname (sbamOpen filename "r" . castPtr) >>= newInHandle filename

-- | Open a BAM (binary) format file
openBamInFile :: FilePath -> IO InHandle
openBamInFile filename = sbamOpen filename "rb" nullPtr >>= newInHandle filename

finalizeSamFile :: MVar (Ptr SamFileInt) -> IO ()
finalizeSamFile mv = modifyMVar mv $ \fsam -> do
  unless (fsam == nullPtr) $ sbamClose fsam
  return (nullPtr, ())

-- | Close a SAM/BAM format alignment input handle
-- 
-- Target sequence set data is still available after the file input
-- has been closed.
closeInHandle :: InHandle -> IO ()
closeInHandle = finalizeSamFile . samfile

-- | Run an IO action using a handle to a TAM format file that will be
-- opened (see 'openTamInFile') and closed for the action.
withTamInFile :: FilePath -> (InHandle -> IO a) -> IO a
withTamInFile filename = bracket (openTamInFile filename) closeInHandle

-- | As 'withTamInFile' with a separate target sequence index set (see
-- 'openTamInFileWithIndex')
withTamInFileWithIndex :: FilePath -> FilePath -> (InHandle -> IO a) -> IO a
withTamInFileWithIndex filename indexname = bracket (openTamInFileWithIndex filename indexname) closeInHandle

-- | As 'withTamInFile' for BAM (binary) format files
withBamInFile :: FilePath -> (InHandle -> IO a) -> IO a
withBamInFile filename = bracket (openBamInFile filename) closeInHandle

-- | Reads one alignment from an input handle, or returns @Nothing@ for end-of-file
get1 :: InHandle -> IO (Maybe Bam1)
get1 inh = withMVar (samfile inh) $ \fsam -> do
  b <- bamInit1
  res <- sbamRead fsam b 
  if res < 0
     then do bamDestroy1 b
             if res < -1
                then ioError . userError $ "Error reading from BAM file " ++ show (inFilename inh)
                else return Nothing
    else do bptr <- newForeignPtr bamDestroy1Ptr b
            return . Just $ Bam1 { ptrBam1 = bptr, header = inHeader inh }

-- | Handle for writing SAM/BAM format alignments
data OutHandle = OutHandle { outFilename :: !FilePath
                           , outfile :: !(MVar (Ptr SamFileInt))
                           , outHeader :: !Header -- ^ Target sequence set for the alignments
                           }

newOutHandle :: String -> FilePath -> Header -> IO OutHandle
newOutHandle mode filename hdr = do
  fsam <- withForeignPtr (unHeader hdr) $ sbamOpen filename mode . castPtr
  when (fsam == nullPtr) $ ioError . userError $ "Error opening BAM file " ++ show filename
  mv <- newMVar fsam
  addMVarFinalizer mv (finalizeSamFile mv)
  return $ OutHandle { outFilename = filename, outfile = mv, outHeader = hdr }
  
-- | Open a TAM format file with @\@SQ@ headers for writing alignments
openTamOutFile :: FilePath -> Header -> IO OutHandle
openTamOutFile = newOutHandle "wh"

-- | Open a BAM format file for writing alignments
openBamOutFile :: FilePath -> Header -> IO OutHandle
openBamOutFile = newOutHandle "wb"
  
-- | Close an alignment output handle
closeOutHandle :: OutHandle -> IO ()
closeOutHandle = finalizeSamFile . outfile

withTamOutFile :: FilePath -> Header -> (OutHandle -> IO a) -> IO a
withTamOutFile filename hdr = bracket (openTamOutFile filename hdr) closeOutHandle

withBamOutFile :: FilePath -> Header -> (OutHandle -> IO a) -> IO a
withBamOutFile filename hdr = bracket (openBamOutFile filename hdr) closeOutHandle

-- | Writes one alignment to an input handle.
-- 
-- There is no validation that the target sequence set of the output
-- handle matches the target sequence set of the alignment.
put1 :: OutHandle -> Bam1 -> IO ()
put1 outh b = withMVar (outfile outh) $ \fsam -> 
  withForeignPtr (ptrBam1 b) $ \p ->
  sbamWrite fsam p >>= handleRes
    where handleRes res | res > 0 = return ()
                        | otherwise = ioError . userError $ "Error writing to BAM file " ++ show (outFilename outh)
 

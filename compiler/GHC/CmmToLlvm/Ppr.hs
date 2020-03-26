{-# LANGUAGE CPP #-}

-- ----------------------------------------------------------------------------
-- | Pretty print helpers for the LLVM Code generator.
--
module GHC.CmmToLlvm.Ppr (
        pprLlvmCmmDecl, pprLlvmData, infoSection
    ) where

#include "HsVersions.h"

import GHC.Prelude

import GHC.Llvm
import GHC.CmmToLlvm.Base
import GHC.CmmToLlvm.Data

import GHC.Cmm.CLabel
import GHC.Cmm

import GHC.Data.FastString
import GHC.Utils.Outputable
import GHC.Types.Unique

-- ----------------------------------------------------------------------------
-- * Top level
--

-- | Pretty print LLVM data code
pprLlvmData :: LlvmOpts -> LlvmData -> SDoc
pprLlvmData opts (globals, types) =
    let ppLlvmTys (LMAlias    a) = ppLlvmAlias a
        ppLlvmTys (LMFunction f) = ppLlvmFunctionDecl f
        ppLlvmTys _other         = empty

        types'   = vcat $ map ppLlvmTys types
        globals' = ppLlvmGlobals opts globals
    in types' $+$ globals'


-- | Pretty print LLVM code
pprLlvmCmmDecl :: LlvmCmmDecl -> LlvmM (SDoc, [LlvmVar])
pprLlvmCmmDecl (CmmData _ lmdata) = do
  opts <- getLlvmOpts
  return (vcat $ map (pprLlvmData opts) lmdata, [])

pprLlvmCmmDecl (CmmProc mb_info entry_lbl live (ListGraph blks))
  = do let lbl = case mb_info of
                     Nothing -> entry_lbl
                     Just (CmmStaticsRaw info_lbl _) -> info_lbl
           link = if externallyVisibleCLabel lbl
                      then ExternallyVisible
                      else Internal
           lmblocks = map (\(BasicBlock id stmts) ->
                                LlvmBlock (getUnique id) stmts) blks

       funDec <- llvmFunSig live lbl link
       dflags <- getDynFlags
       opts <- getLlvmOpts
       platform <- getPlatform
       let buildArg = fsLit . showSDoc dflags . ppPlainName opts
           funArgs = map buildArg (llvmFunArgs platform live)
           funSect = llvmFunSection opts (decName funDec)

       -- generate the info table
       prefix <- case mb_info of
                     Nothing -> return Nothing
                     Just (CmmStaticsRaw _ statics) -> do
                       infoStatics <- mapM genData statics
                       let infoTy = LMStruct $ map getStatType infoStatics
                       return $ Just $ LMStaticStruc infoStatics infoTy


       let fun = LlvmFunction funDec funArgs llvmStdFunAttrs funSect
                              prefix lmblocks
           name = decName $ funcDecl fun
           defName = llvmDefLabel name
           funcDecl' = (funcDecl fun) { decName = defName }
           fun' = fun { funcDecl = funcDecl' }
           funTy = LMFunction funcDecl'
           funVar = LMGlobalVar name
                                (LMPointer funTy)
                                link
                                Nothing
                                Nothing
                                Alias
           defVar = LMGlobalVar defName
                                (LMPointer funTy)
                                (funcLinkage funcDecl')
                                (funcSect fun)
                                (funcAlign funcDecl')
                                Alias
           alias = LMGlobal funVar
                            (Just $ LMBitc (LMStaticPointer defVar)
                                           i8Ptr)

       return (ppLlvmGlobal opts alias $+$ ppLlvmFunction opts fun', [])


-- | The section we are putting info tables and their entry code into, should
-- be unique since we process the assembly pattern matching this.
infoSection :: String
infoSection = "X98A__STRIP,__me"

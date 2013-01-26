module Csound.Render where

import Data.List(transpose)
import Data.Maybe(catMaybes)
import qualified Data.Map as M

import Temporal.Media(eventEnd)
import Control.Monad.Trans.State(evalState)

import Text.PrettyPrint
import Data.Fix

import Csound.Exp
import Csound.Exp.Wrapper hiding (double, int)
import Csound.Tfm.TfmTree(ftableMap)
import Csound.Render.Sco
import Csound.Render.Instr
import Csound.Render.Options
import Csound.Tfm.TfmTree(FtableMap)
import Csound.Exp.Numeric

import Csound.Opcode(clip, zeroDbfs)

out :: Sig -> SE [Sig]
out = return . return

mixing :: [[Sig]] -> SE [Sig]
mixing = return . fmap sum . transpose

mixingBy :: ([Sig] -> SE [Sig]) -> ([[Sig]] -> SE [Sig])
mixingBy f = (f =<<) . mixing 

csd :: CsdOptions -> ([[Sig]] -> SE [Sig]) -> [SigOut] -> String
csd opt globalEffect as = show $ csdFile 
    (renderFlags opt)
    (renderInstr0 (nchnls lastInstrExp) (massignTable ids as) opt)
    (vcat $ punctuate newline $ firstInstr : lastInstr : zipWith (renderInstr fts) ids instrs)
    (vcat $ firstInstrNote : lastInstrNote : zipWith (renderScores strs fts) ids scos)
    (renderStringTable strs)
    (renderTotalDur $$ renderFtables fts)
    where scos   = map (scoSigOut' . sigOutContent) as          
          (instrs, effects, initOuts) = unzip3 $ zipWith runExpReader as ids    
          fts    = ftableMap $ lastInstrExp : instrs
          strs   = stringMap $ concat scos
          ids    = take nInstr [2 .. ]
          
          nInstr = length as
          firstInstrId = 1
          lastInstrId  = nInstr + 2          
           
          firstInstr = renderInstr fts firstInstrId $ execSE $ sequence_ initOuts
          lastInstr  = renderInstr fts lastInstrId lastInstrExp
          
          lastInstrExp = mixingInstrExp globalEffect effects
           
          scoSigOut' x = case x of
              PlainSigOut _ _ -> scoSigOut x
              _ -> []            

          dur = maybe 64000000 id $ totalDur as
          renderTotalDur = text "f0" <+> double dur
          firstInstrNote = alwayson firstInstrId dur
          lastInstrNote  = alwayson lastInstrId dur
          alwayson instrId time = char 'i' <> int instrId <+> double 0 <+> double dur

csdFile flags instr0 instrs scores strTable ftables = 
    tag "CsoundSynthesizer" [
        tag "CsOptions" [flags],
        tag "CsInstruments" [
            instr0, strTable, instrs],
        tag "CsScore" [
            ftables, scores]]        


massignTable :: [Int] -> [SigOut] -> [Massign]
massignTable ids instrs = catMaybes $ zipWith mk ids instrs
    where mk n instr = case sigOutContent $ instr of
            Midi chn _ -> Just $ Massign chn n
            _ -> Nothing

renderFtables = renderMapTable renderFtableEntry
renderStringTable = renderMapTable renderStringEntry

renderFtableEntry ft id = char 'f' 
    <>  int id 
    <+> int 0 
    <+> (int $ ftableSize ft)
    <+> (int $ ftableGen ft) 
    <+> (hsep $ map double $ ftableArgs ft)
 
renderStringEntry str id = text "strset" <+> int id <> comma <+> (doubleQuotes $ text str)

renderMapTable :: (a -> Int -> Doc) -> M.Map a Int -> Doc
renderMapTable phi = vcat . map (uncurry phi) . M.toList


tag :: String -> [Doc] -> Doc
tag name content = vcat $ punctuate newline [
    char '<' <> text name <> char '>', 
    vcat $ punctuate newline content, 
    text "</" <> text name <> char '>']  

newline = char '\n'


mixingInstrExp :: ([[Sig]] -> SE [Sig]) -> [SE [Sig]] -> E
mixingInstrExp globalEffect effects = execSE $ outs . fmap clip' =<< globalEffect =<< sequence effects
    where clip' x = clip x 0 zeroDbfs
          
totalDur :: [SigOut] -> Maybe Double
totalDur as 
    | null as'  = Nothing
    | otherwise = Just $ maximum $ map eventEnd . scoSigOut =<< as' 
    where as' = filter isNotMidi $ map sigOutContent as
          isNotMidi x = case x of
            Midi _ _ -> False
            _ -> True
  



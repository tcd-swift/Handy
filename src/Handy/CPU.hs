{-# LANGUAGE GADTs #-}
module Handy.CPU where

import Prelude hiding (EQ,LT,GT)

import Handy.Memory
import Handy.Instructions
import Handy.StatusRegister
import Handy.ALU
import Handy.Util (computeBranchOffset, checkCondition)
import qualified Handy.Registers as Reg

import Control.Monad.State
import Data.Int (Int32)
import Data.Word (Word32)
import Data.Bits

type FetchRegister   = Maybe Instruction
type DecodeRegister  = Maybe Instruction
type ExecuteRegister = Maybe Instruction

data Machine = Machine { registers :: Reg.RegisterFile
                       , memory    :: Memory
                       , cpsr      :: StatusRegister
                       , executing :: Bool
                       , fetchR    :: FetchRegister
                       , decodeR   :: DecodeRegister
                       , executeR  :: ExecuteRegister
                       } deriving Show

type Run a = StateT Machine IO a
run :: Run ()
run = do
    running <- gets executing
    when (running) $ do
        modify pipeline
        i <- gets executeR
        execute i
        machine <- get
        modify incPC
        run

{-
    TODO/FIXME:
    Currently decode is a no op because instructions arrive fully formed.
    Later, fetchR should be a "Maybe Word32", and there should be an instruction
    decoder with type Word32 -> Instruction that gets applied to the contents of
    decodeR as they move into executeR
-}

pipeline :: Machine -> Machine
pipeline machine = machine { fetchR   = nextInstruction machine
                           , decodeR  = fetchR machine
                           , executeR = decodeR machine
                           }

flushPipeline :: Machine -> Machine
flushPipeline machine = machine { fetchR   = Nothing
                                , decodeR  = Nothing
                                , executeR = Nothing
                                }

{-
    TODO/FIXME:
    All this bounds checking is only necessary because of the current temporary
    implementation of memory as a list of instructions. Later on this function
    should be simplified a lot by just being a call to the memory.
-}

nextInstruction :: Machine -> Maybe Instruction
nextInstruction machine = let pc = fromIntegral $ (registers machine) `Reg.get` Reg.PC in
                             if pc <= (4 * length (memory machine)) - 1  then
                                Just $ (memory machine) !! (pc `div` 4)
                             else Nothing

setRegister :: Reg.Register -> Int32 -> Machine -> Machine
setRegister r v machine = machine { registers = Reg.set (registers machine) r v }

incPC :: Machine -> Machine
incPC machine = let pc = (registers machine) `Reg.get` Reg.PC in
                  setRegister Reg.PC (pc + 4) machine

execute :: Maybe Instruction -> Run ()
execute Nothing = return ()
execute (Just i) = execute' i

execute' :: Instruction -> Run ()

execute' HALT = state $ (\machine -> ((),machine { executing = False }))

execute' (B cond src) = do machine <- get
                           when (checkCondition cond $ cpsr machine) $ do
                               let (rf,_) = computeBranch src cond (registers machine) (cpsr machine)
                               put $ machine { registers = rf }
                               modify $ flushPipeline


execute' (BL cond src) = do machine <- get
                            let rf = registers machine
                            when (checkCondition cond $ cpsr machine) $ do
                                let link = (rf `Reg.get` Reg.PC) - 4
                                modify $ setRegister Reg.LR link
                            execute' (B cond src)

execute' (BX cond src) = do machine <- get
                            let rf = registers machine
                            let sr = cpsr machine
                            let (ArgR dest) = src
                            when (checkCondition cond $ sr) $ do
                                let (rf',_) = compute (AND cond NoS Reg.PC src (ArgC 0xFFFFFFFE) NoShift) rf sr
                                let (rf'',_) = compute (SUB cond NoS Reg.PC src (ArgC 4) NoShift) rf' sr
                                put $ machine { registers = rf'' }
                                modify $ flushPipeline

execute' i = do machine <- get
                when (checkCondition (getCondition i) (cpsr machine)) $ do
                    let (rf,sr) = compute i (registers machine) (cpsr machine)
                    put $ machine { cpsr = sr, registers = rf }




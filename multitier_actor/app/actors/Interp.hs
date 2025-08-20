
-- The syntax is based on the implicitrefs language, and
-- the semantics is based on the one for the continuation-based language.
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use camelCase" #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BlockArguments #-}

module Interp where

import Expr
import EnvStore
import ActorName(RoleName)
import NodeRegistry(NodeMessage(..))
import SystemMessage

import System.IO (hFlush, stdout)
import System.Random (randomRIO)

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Monad (forever)
import Control.Concurrent (threadDelay)
import Control.Monad.Cont (MonadIO(liftIO))

import qualified Data.Map as Map

-- Continuation

data Cont =
    End_Main_Thread_Cont
  | Init_Main_Actor_Cont Cont
  | Zero1_Cont Cont
  | Let_Exp_Cont Identifier Exp Env Cont
  | If_Test_Cont Exp Exp Env Cont
  -- | Diff1_Cont Exp Env Cont
  -- | Diff2_Cont ExpVal Cont
  | BinOp1_Cont BinaryOp Exp Env Cont
  | BinOp2_Cont BinaryOp ExpVal Cont
  | Rator_Cont Exp Env Cont
  | Rand_Cont ExpVal Env Cont
  | Unop_Arg_Cont UnaryOp Cont
  | Comp1_Cont CompOp Exp Env Cont
  | Comp2_Cont CompOp ExpVal Cont
  | Set_Rhs_Cont Identifier Env Cont

  | Send_Cont [Exp] [ExpVal] Env Cont
  | Ready_Cont Cont
  | RemoteReady_Cont Cont
  | New_Cont Cont

  | Tuple_Cont [Exp] [ExpVal] Env Cont
  | Let_Tuple_Cont [Identifier] Exp Env Cont
  | Append_Cont Identifier Env Cont

  | PowMod_Cont [Exp] [ExpVal] Env Cont
    
instance Show Cont where
  show End_Main_Thread_Cont = "End_Main_Thread_Cont"
  show (Init_Main_Actor_Cont cont) = "Init_Main_Actor_Cont " ++ show cont
  show (Zero1_Cont _) = "Zero1_Cont"
  show (Let_Exp_Cont var body _ _) = "Let_Exp_Cont " ++ var 
  show (If_Test_Cont exp2 exp3 _ _) = "If_Test_Cont " 
  -- show (Diff1_Cont exp2 _ _) = "Diff1_Cont " ++ show exp2 
  -- show (Diff2_Cont val _) = "Diff2_Cont " ++ show val
  show (Rator_Cont rand _ _) = "Rator_Cont"
  show (Rand_Cont ratorVal _ _) = "Rand_Cont " ++ show ratorVal
  show (Unop_Arg_Cont op _) = "Unop_Arg_Cont" ++ show op
  show (BinOp1_Cont op exp2 _ _) = "BinOp1_Cont " ++ show op
  show (BinOp2_Cont op val1 _) = "BinOp2_Cont " ++ show op
  show (Comp1_Cont op exp2 _ _) = "Comp1_Cont " ++ show op
  show (Comp2_Cont op val1 _) = "Comp2_Cont " ++ show op
  show (Set_Rhs_Cont var _ _) = "Set_Rhs_Cont " ++ var 

  show (Send_Cont explist vals _ _) =
    let explistStr = unwords $ map show explist
        valsStr = unwords $ map show vals
    in  "Send_Cont [" ++ explistStr ++ "] [" ++ valsStr ++ "]"

  show (Ready_Cont _) = "Ready_Cont"

  show (RemoteReady_Cont _) = "RemoteReady_Cont"    
  show (New_Cont _) = "New_Cont"
  show (Tuple_Cont explist vals _ _) =
    let explistStr = unwords $ map show explist
        valsStr = unwords $ map show vals
    in  "Tuple_Cont [" ++ explistStr ++ "] [" ++ valsStr ++ "]"
  show (Let_Tuple_Cont vars _ _ _) = "Let_Tuple_Cont " ++ unwords vars
  show (Append_Cont var _ _) = "Append_Cont " ++ var

  show (PowMod_Cont explist vals _ _) =
    let explistStr = unwords $ map show explist
        valsStr = unwords $ map show vals
    in  "PowMod_Cont [" ++ explistStr ++ "] [" ++ valsStr ++ "]"


apply_cont :: Cont -> ExpVal -> Store -> ActorState -> Process (FinalAnswer, Store)

apply_cont cont expval store actors = 
  do current <- getSelfPid
     -- liftIO $ putStrLn $ "["  ++ show current ++ "] " ++ "apply_cont: " ++ show cont 
     apply_cont' cont expval store actors 

apply_cont' :: Cont -> ExpVal -> Store -> ActorState -> Process (FinalAnswer, Store)

apply_cont' End_Main_Thread_Cont v store actors = do
  return (v, store)

apply_cont' (Init_Main_Actor_Cont cont) v store actors = do
  current <- getSelfPid
  let p = expval_proc v
      v1 = Actor_Val current
  apply_procedure_k p v1 cont store actors

apply_cont' (Zero1_Cont cont) num1 store actors =
  apply_cont cont
    (if expval_num num1 == 0
     then Bool_Val True
     else Bool_Val False) store actors

apply_cont' (Let_Exp_Cont var body env cont) val store actors = do
  current <- getSelfPid
  case val of
    Actor_Val aid -> do
      let (loc,store') = newref store val
          env1 = extend_env current var loc env
      value_of_k body (extend_env_with_actorId var aid env1) cont store' actors
    _ -> do
      let (loc,store') = newref store val
      value_of_k body (extend_env current var loc env) cont store' actors

apply_cont' (If_Test_Cont exp2 exp3 env cont) v store actors =
  if expval_bool v
  then value_of_k exp2 env cont store actors
  else value_of_k exp3 env cont store actors

-- apply_cont' (Diff1_Cont exp2 env cont) val1 store actors =
--   value_of_k exp2 env (Diff2_Cont val1 cont) store actors

-- apply_cont' (Diff2_Cont val1 cont) val2 store actors =
--   let num1 = expval_num val1
--       num2 = expval_num val2
--   in apply_cont cont (Num_Val (num1 - num2)) store actors

apply_cont' (BinOp1_Cont op e2 env cont) val1 store actors =
  value_of_k e2 env (BinOp2_Cont op val1 cont) store actors

apply_cont' (BinOp2_Cont op val1 cont) val2 store actors = do
  res <- apply_binop op val1 val2
  apply_cont cont res store actors

apply_cont' (Unop_Arg_Cont op cont) val store actors = do
  res <- apply_unop op val
  apply_cont cont res store actors

apply_cont' (Comp1_Cont op exp2 env cont) val1 store actors = 
  value_of_k exp2 env (Comp2_Cont op val1 cont) store actors

apply_cont' (Comp2_Cont op val1 cont) val2 store actors = 
  let res = case op of
        Eq -> Bool_Val (val1 == val2)
  in apply_cont cont res store actors

apply_cont' (Rator_Cont rand env cont) ratorVal store actors =
  value_of_k rand env (Rand_Cont ratorVal env cont) store actors

apply_cont' (Rand_Cont ratorVal env cont) randVal store actors = do
  current <- getSelfPid
  let proc = expval_proc ratorVal
      Procedure saved_actor _ _ _ = proc
  if saved_actor == current
  then apply_procedure_k proc randVal cont store actors
  else do
    send saved_actor (RemoteCall (ratorVal, randVal) current)
    apply_cont (RemoteReady_Cont cont) Unit_Val store actors

apply_cont' (Set_Rhs_Cont var env cont) val store actors = do
  let saved_actor = lookup_env env var
  current <- getSelfPid
  if saved_actor == current
  then
      let (loc, store1) = apply_env env store var
          store2 = setref store1 loc val
      in apply_cont cont (Unit_Val) store2 actors
  else do
    let (loc, store1) = apply_env env store var
    send saved_actor (RemoteSet (loc, val) current)
    apply_cont (RemoteReady_Cont cont) Unit_Val store1 actors

apply_cont' (Send_Cont explist vals env saved_cont) val store actors = do
  let vals' = vals ++ [val]
  case explist of
    (exp:exps) -> value_of_k exp env (Send_Cont exps vals' env saved_cont) store actors
    [] -> case vals' of
            (v:vs) -> do
              case v of
                Actor_Val pid -> do
                  let pid = expval_actor v
                  mapM_ (send pid) vs       -- send :: (Serializable msg) => ProcessId -> msg -> Process ()
                  apply_cont saved_cont (Unit_Val) store actors
                List_Val pids -> do
                  -- 리스트 안의 각 Actor_Val에 메시지 전송
                  let maybePids = [ expval_actor av | av@(Actor_Val _) <- pids ]
                  mapM_ (\pid -> mapM_ (send pid) vs) maybePids
                  apply_cont saved_cont Unit_Val store actors

apply_cont' (Ready_Cont saved_cont) val store actors = do
  current <- getSelfPid
  receiveWait
    [ match $ \(msg :: RemoteMessage) -> do
        case msg of
          -- 변수 read 요청 처리
          RemoteVar varLoc requester -> do
            let returnVal = deref store varLoc
            send requester (ReturnMessage returnVal)
            apply_cont (Ready_Cont saved_cont) val store actors
          -- 변수 write 요청 처리
          RemoteSet (varLoc, val') requester -> do
            let store1 = setref store varLoc val'
            send requester (ReturnMessage Unit_Val)
            apply_cont (Ready_Cont saved_cont) val store1 actors
          -- 프로시저 생성 (Proc) 요청 처리
          RemoteProc idx savedEnv requester -> do
            let m = procMap actors
            case Map.lookup idx m of
              Just (Proc_Exp _ var body) -> do
                let returnVal = Proc_Val (procedure current var body savedEnv)
                send requester (ReturnMessage returnVal)
                apply_cont (Ready_Cont saved_cont) val store actors
              Nothing -> error $ "Invalid RemoteProc index: " ++ show idx
          -- 프로시저 호출 요청 처리
          RemoteCall (ratorVal, randVal) requester -> do
            let proc = expval_proc ratorVal
            (returnVal, store1) <- apply_procedure_k proc randVal End_Main_Thread_Cont store actors
            send requester (ReturnMessage returnVal)
            apply_cont (Ready_Cont saved_cont) val store1 actors
      ,
      match $ \(msg :: ExpVal) -> do
        let Procedure _ x body env = expval_proc val
            (loc, store1) = newref store msg
        let env1 = extend_env current x loc env
        value_of_k body env1 saved_cont store1 actors
    ]

apply_cont' (RemoteReady_Cont saved_cont) val store actors = do
  current <- getSelfPid
  receiveWait
    [ match $ \(msg :: ReturnMessage) -> do
        let ReturnMessage returnVal = msg
        apply_cont saved_cont returnVal store actors
      ,
      match $ \(msg :: RemoteMessage) -> do
        case msg of
          RemoteVar varLoc requester -> do
            let returnVal = deref store varLoc
            send requester (ReturnMessage returnVal)
            apply_cont (RemoteReady_Cont saved_cont) val store actors

          RemoteSet (varLoc, val') requester -> do
            let store1 = setref store varLoc val'
            send requester (ReturnMessage Unit_Val)
            apply_cont (RemoteReady_Cont saved_cont) val store1 actors

          RemoteProc idx savedEnv requester -> do
            let m = procMap actors
            case Map.lookup idx m of
              Just (Proc_Exp _ var body) -> do
                let returnVal = Proc_Val (procedure current var body savedEnv)
                send requester (ReturnMessage returnVal)
                apply_cont (Ready_Cont saved_cont) val store actors
              Nothing -> error $ "Invalid RemoteProc index: " ++ show idx

          RemoteCall (ratorVal, randVal) requester -> do
            let proc = expval_proc ratorVal
            (returnVal, store1) <- apply_procedure_k proc randVal End_Main_Thread_Cont store actors
            send requester (ReturnMessage returnVal)
            apply_cont (RemoteReady_Cont saved_cont) val store1 actors
    ]

apply_cont' (New_Cont saved_cont) val store actors = do
  current <- getSelfPid
  let Procedure saved_actor x body env = expval_proc val
  if saved_actor == current
  then do
    -- 로컬에서 액터를 생성(spawnLocal)
    newPid <- spawnLocal $ do
                self <- getSelfPid
                let (loc, store1) = newref initStore (Actor_Val self)
                    env1 = extend_env self x loc env
                _ <- value_of_k body env1 End_Main_Thread_Cont store1 actors
                forever $ liftIO $ threadDelay maxBound
    apply_cont saved_cont (Actor_Val newPid) store actors
  else do
    -- 원격 액터에 behavior 실행
    send saved_actor (RemoteCall (val, (Actor_Val saved_actor)) current)
    apply_cont saved_cont (Actor_Val saved_actor) store actors

apply_cont' (Tuple_Cont explist vals env saved_cont) val store actors = do
  let vals' = vals ++ [val] in
    case explist of
      (exp:exps) -> value_of_k exp env (Tuple_Cont exps vals' env saved_cont) store actors
      [] -> let tuple = List_Val vals' 
            in apply_cont saved_cont tuple store actors

apply_cont' (Let_Tuple_Cont vars body env saved_cont) val store actors = do
  current <- getSelfPid
  case val of
    List_Val vals -> 
      if vars == [] && null vals
      then value_of_k body env saved_cont store actors
      else let (env', store') = bind_vars current vars vals env store
           in value_of_k body env' saved_cont store' actors
    _ -> error ("LetTuple_Cont: expected a list, got " ++ show val)

apply_cont' (Append_Cont var env cont) val store actors = do
  let (loc, store1) = apply_env env store var
      List_Val xs = deref store1 loc
      xs' = xs ++ [val]
      store2 = setref store1 loc (List_Val xs')
  apply_cont cont (Unit_Val) store2 actors

apply_cont' (PowMod_Cont explist vals env saved_cont) val store actors = do
  let vals' = vals ++ [val]
  case explist of
    (exp:exps) -> value_of_k exp env (PowMod_Cont exps vals' env saved_cont) store actors
    [] -> case vals' of
            (v1:v2:v3:[]) -> do
              let res = powMod (expval_num v1) (expval_num v2) (expval_num v3)
              apply_cont saved_cont (Num_Val res) store actors
            _ -> error "PowMod_Cont: expected 3 values"

apply_unop :: UnaryOp -> ExpVal -> Process ExpVal

apply_unop IsZero (Num_Val num)
  | num==0    = return $ Bool_Val True
  | otherwise = return $ Bool_Val False
apply_unop IsNull (List_Val [])  = return $ Bool_Val True
apply_unop IsNull (List_Val _)   = return $ Bool_Val False
apply_unop Car (List_Val (x:_))  = return $ x
apply_unop Cdr (List_Val (_:xs)) = return $ List_Val xs
apply_unop Print v = do
  liftIO $ putStr (show v)
  return Unit_Val
apply_unop Read _ = do
  liftIO $ hFlush stdout
  line <- liftIO getLine
  -- 입력 받은 직후, 이전 줄 지우기(ANSI escape code)
  -- 커서를 한 줄 위로 올리고, 줄 전체 지우기
  liftIO $ putStr "\ESC[A"    -- 커서 위로 한 줄
  liftIO $ putStr "\ESC[2K"   -- 줄 전체 지우기
  liftIO $ hFlush stdout
  return $ Str_Val line
apply_unop ReadInt _ = do
  liftIO $ hFlush stdout
  line <- liftIO getLine
  -- 입력 받은 직후, 이전 줄 지우기(ANSI escape code)
  -- 커서를 한 줄 위로 올리고, 줄 전체 지우기
  liftIO $ putStr "\ESC[A"    -- 커서 위로 한 줄
  liftIO $ putStr "\ESC[2K"   -- 줄 전체 지우기
  liftIO $ hFlush stdout
  return $ Num_Val (read line :: Int)
apply_unop op rand = error ("Unknown unary operator: :" ++ show op ++ " " ++ show rand)

apply_binop :: BinaryOp -> ExpVal -> ExpVal -> Process ExpVal
apply_binop Add (Num_Val n1) (Num_Val n2) = return $ Num_Val (n1 + n2)
apply_binop Diff (Num_Val n1) (Num_Val n2) = return $ Num_Val (n1 - n2)
apply_binop Mul (Num_Val n1) (Num_Val n2) = return $ Num_Val (n1 * n2)
apply_binop Mod (Num_Val n1) (Num_Val n2) = return $ Num_Val (n1 `mod` n2)
apply_binop Random (Num_Val n1) (Num_Val n2) = do
  r <- liftIO $ randomRIO (n1, n2)
  return $ Num_Val r
apply_binop _   _             _           = error "Type error in binary op"

value_of_k :: Exp -> Env -> Cont -> Store -> ActorState -> Process (FinalAnswer, Store)
value_of_k exp env cont store actors = 
  do current <- getSelfPid
     -- liftIO $ putStrLn $ "["  ++ show current ++ "] " ++ "value_of_k: " ++ take 100 (show exp)
     value_of_k' exp env cont store actors 

value_of_k' :: Exp -> Env -> Cont -> Store -> ActorState -> Process (FinalAnswer, Store)

value_of_k' (Const_Exp n) env cont store actors =
  apply_cont cont (Num_Val n) store actors

value_of_k' (Const_List_Exp nums) env cont store actors =
  apply_cont cont (List_Val (map Num_Val nums)) store actors

value_of_k' (Str_Exp str) env cont store actors = do
  let strVal = Str_Val str
  apply_cont cont strVal store actors

value_of_k' (Pid_Exp pid) env cont store actors = do
  let pidVal = Actor_Val pid
  apply_cont cont pidVal store actors

value_of_k' (Var_Exp var) env cont store actors = do
  current <- getSelfPid
  let saved_actor = lookup_env env var
      (loc, store') = apply_env env store var
  if saved_actor == current
  then do
    let val = deref store' loc
    apply_cont cont val store' actors
  else do
    send saved_actor (RemoteVar loc current)
    apply_cont (RemoteReady_Cont cont) Unit_Val store' actors

-- value_of_k' (Diff_Exp exp1 exp2) env cont store actors =
--   value_of_k exp1 env (Diff1_Cont exp2 env cont) store actors

value_of_k' (Unary_Exp op exp1) env cont store actors =
  value_of_k exp1 env (Unop_Arg_Cont op cont) store actors

value_of_k' (Binary_Exp op exp1 exp2) env cont store actors =
  value_of_k exp1 env (BinOp1_Cont op exp2 env cont) store actors

value_of_k' (Comp_Exp op exp1 exp2) env cont store actors =
  value_of_k exp1 env (Comp1_Cont op exp2 env cont) store actors

value_of_k' (If_Exp exp1 exp2 exp3) env cont store actors =
  value_of_k exp1 env (If_Test_Cont exp2 exp3 env cont) store actors

value_of_k' (Let_Exp var exp1 body) env cont store actors =
  value_of_k exp1 env (Let_Exp_Cont var body env cont) store actors

value_of_k' (Letrec_Exp nameActorNameArgBodyList letrec_body) env cont store actors = do
  current <- getSelfPid
  let nameActorIdArgBodyList =
        [ case maybeActorName of
            Nothing -> (p_name, current, b_var, p_body)
            Just actorName ->
              let (loc, store1) = apply_env env store actorName   -- Ignore store1!!
                  actorId  = expval_actor(deref store1 loc)
              in (p_name,actorId,b_var,p_body)
          | (p_name,maybeActorName,b_var,p_body) <- nameActorNameArgBodyList ]
  value_of_k letrec_body (extend_env_rec nameActorIdArgBodyList env) cont store actors

-- value_of_k' (Proc_Exp (Just actorName) var body) env cont store actors = do
--   current <- getSelfPid
--   let actorId = lookup_actorId env actorName
--   if actorId == current
--   then apply_cont cont (Proc_Val (procedure current var body env)) store actors
--   else do
--     send actorId (RemoteProc (Proc_Exp Nothing var body) env current)
--     apply_cont (RemoteReady_Cont cont) Unit_Val store actors

value_of_k' (Proc_Exp Nothing var body) env cont store actors = do
  current <- getSelfPid
  apply_cont cont (Proc_Val (procedure current var body env)) store actors

value_of_k' (PtrTo_Exp i) env cont store actors = do
  current <- getSelfPid
  let m = procMap actors
  case Map.lookup i m of
    Just (Proc_Exp (Just actorName) var body) -> do
      let actorId = lookup_actorId env actorName
      if actorId == current
      then apply_cont cont (Proc_Val (procedure current var body env)) store actors
      else do
        send actorId (RemoteProc i env current)
        apply_cont (RemoteReady_Cont cont) Unit_Val store actors
    Just (Proc_Exp Nothing var body) -> do
      apply_cont cont (Proc_Val (procedure current var body env)) store actors
    _ -> error $ "Invalid PtrTo_Exp index: " ++ show i

value_of_k' (Call_Exp rator rand) env cont store actors =
  value_of_k rator env (Rator_Cont rand env cont) store actors

value_of_k' (Block_Exp [exp]) env cont store actors =
  value_of_k exp env cont store actors

value_of_k' (Block_Exp (exp:exps)) env cont store actors =
  value_of_k (Call_Exp (Proc_Exp Nothing "$dummy" (Block_Exp exps)) exp) env cont store actors

value_of_k' (Block_Exp []) env cont store actors =
  error "Unexpected empty block" 

value_of_k' (Set_Exp x exp) env cont store actors =
  value_of_k exp env (Set_Rhs_Cont x env cont) store actors

-- For actors
value_of_k' (Send_Exp (exp:exps)) env cont store actors =
  value_of_k exp env (Send_Cont exps [] env cont) store actors

value_of_k' (Ready_Exp exp) env cont store actors =
  value_of_k exp env (Ready_Cont cont) store actors

value_of_k' (New_Exp exp) env cont store actors =
  value_of_k exp env (New_Cont cont) store actors

-- For tuple
value_of_k' (Tuple_Exp []) env cont store actors =
  apply_cont cont (List_Val []) store actors

value_of_k' (Tuple_Exp (exp:exps)) env cont store actors =
  value_of_k exp env (Tuple_Cont exps [] env cont) store actors

value_of_k' (LetTuple_Exp vars exp1 exp2) env cont store actors =
  value_of_k exp1 env (Let_Tuple_Cont vars exp2 env cont) store actors

value_of_k' (Append_Exp exp1 exp2) env cont store actors =
  value_of_k exp2 env (Append_Cont exp1 env cont) store actors

value_of_k' (PowMod_Exp e1 e2 e3) env cont store actors =
  value_of_k e1 env (PowMod_Cont [e2, e3] [] env cont) store actors

value_of_k' exp _ _ _ _ =
  error $ "Unknown expression in value_of_k" ++ show exp


--
value_of_program :: Exp -> Map.Map Int Exp -> Process (FinalAnswer, Store)
value_of_program exp procMap = do
  nid <- getSelfNode
  (finalVal, store) <- value_of_k exp initEnv (Init_Main_Actor_Cont End_Main_Thread_Cont) initStore (initActorState nid procMap)
  return (finalVal, store)

--
initEnv = empty_env


apply_procedure_k :: Proc -> ExpVal -> Cont -> Store -> ActorState -> Process (FinalAnswer, Store)
apply_procedure_k (Procedure saved_actor var body saved_env) arg cont store actors = do
  case arg of
    Actor_Val aid -> do
      let (loc,store') = newref store arg
          env1 = extend_env saved_actor var loc saved_env
      value_of_k body (extend_env_with_actorId var aid env1) cont store' actors
    _ -> do
      let (loc,store') = newref store arg
      value_of_k body (extend_env saved_actor var loc saved_env) cont store' actors

  
--
powMod :: Int -> Int -> Int -> Int
powMod base expr modulo = pow base expr 1
  where
    pow _ 0 acc = acc
    pow b e acc = pow b' e' acc'
      where
        (e', b', acc') =
          if even e
          then (e `div` 2, (b * b) `mod` modulo, acc)
          else (e - 1, b, (acc * b) `mod` modulo)
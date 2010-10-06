structure Semant:
sig
  val transProg: Absyn.exp -> unit

  (* XXX: Don't think these declaration below really need exporting. *)
  type expty

  val transVar: Env.venv * Env.tenv * Absyn.var -> expty
  val transExp: Env.venv * Env.tenv * Absyn.exp -> expty
  val transDec: Env.venv * Env.tenv * Absyn.dec -> {venv: Env.venv, tenv: Env.tenv}
  val transTy:             Env.tenv * Absyn.ty  -> Types.ty
end =
struct
  structure A = Absyn
  structure S = Symbol
  structure E = Env
  structure T = Types

  open List

  type expty = {exp: Translate.exp, ty: T.ty}

  val todoAccess = ()
  val todoTy = T.INT
  val todoTrExp = ()
  val todoExpTy = {exp=(), ty=todoTy}
  val todoDecValEntTyEnv = {venv=E.base_venv, tenv=E.base_tenv}

  (* Value to use when expression is in error and no better value/ty can be provided *)
  val errorExpTy = {exp=todoTrExp, ty=T.NIL}
  val errorTrExp = ()

  val error = ErrorMsg.error

  fun lookupTy(pos, tenv, ty) =
    case S.look(tenv, ty)
      of SOME ty => ty
       | NONE   => (error pos "type does not exist"; T.NIL)

  fun digType(pos, tenv, T.NAME (sym, _)) = digType(pos, tenv, lookupTy(pos, tenv, sym))
    | digType(pos, tenv, ty) = ty

  (* TODO: allow type aliases/synonyms *)
  fun checkInt({exp, ty}, pos) =
    case ty
      of T.INT => ()
      | _ => error pos "Type 'int' required"

  (* TODO: allow type aliases/synonyms *)
  fun checkUnit({exp, ty}, pos) =
    case ty
      of T.UNIT => ()
      | _ => error pos "unit required"

  (* TODO: allow records to be compatible with NIL from either left or right? *)
  fun reqSameType(pos, tenv, {exp=_, ty=ty1}, {exp=_, ty=ty2}) =
    let val t1 = digType(pos, tenv, ty1)
        val t2 = digType(pos, tenv, ty2)
    in
      if t1 <> t2 then
        case t1
          of T.RECORD _ => if t2 = T.NIL then () else (error pos "types do not match"; ())
           | _          => error pos "types do not match" (* TODO: better msg here *)
      else ()
    end

  fun findVarType(tenv, venv, A.SimpleVar (sym, pos)) =
    (case S.look(venv, sym)
      of SOME(E.VarEntry {ty}) => ty (* XXX: probably need digType here *)
       | SOME(E.FunEntry _) => (error pos "Cannot assign to a function"; T.NIL)
       | _ => (error pos "Variable does not exist"; T.NIL)
    )

    | findVarType(tenv, venv, A.FieldVar (var, sym, pos)) =
      let
        (* XXX: probably need digType here *)
        val ty = findVarType(tenv, venv, var) (* Lookup type of nested var. It should be a record type. *)
      in
        case ty
          of T.RECORD (fields, unique) =>
            (case List.find (fn (fSym, fTy) => fSym = sym) fields
              of SOME(sym, ty) => ty
              |  NONE          => (error pos ("field " ^ S.name sym ^ " does not exist"); T.NIL)
            )
          |  _                       => (error pos "variable is not a record"; T.NIL)
      end

    | findVarType(tenv, venv, A.SubscriptVar (var, exp, pos)) =
      let
        (* Lookup type of nested var. It should be an array type. Dig past type aliases (NAME types). *)
        val ty = digType(pos, tenv, findVarType(tenv, venv, var)) 
        val expA = transExp(venv, tenv, exp)
      in
        case ty
          of T.ARRAY (ty, unique) => (reqSameType(pos, tenv, expA, {exp=(), ty=T.INT}); ty)
          |  _                    => (error pos "variable is not an array"; T.NIL)
      end

  and transVar(venv, tenv, var) = todoExpTy

  and actualTy(pos, tenv, ty) = 
    digType(pos, tenv, ty) (* XXX: Is this correct? *)

  and transDec(venv, tenv, A.VarDec {name, escape, typ=NONE, init, pos}) =
    let val {exp=_ (*TODO*), ty} = transExp(venv, tenv, init)
    in {tenv=tenv, venv=S.enter(venv, name, E.VarEntry {ty=ty})}
    end

  |   transDec(venv, tenv, A.VarDec {name, escape, typ=SOME(symbol, decTyPos), init, pos}) =
    let val {exp=_ (*TODO*), ty} = transExp(venv, tenv, init)
        val SOME(decTy) = S.look(tenv, symbol)
    in (
      reqSameType(pos, tenv, {exp=(), ty=decTy}, {exp=(), ty=ty});
      {tenv=tenv, venv=S.enter(venv, name, E.VarEntry {ty=decTy})} (* continue with declared type *)
    )
    end

  |  transDec(venv, tenv, A.TypeDec []) = {tenv=tenv, venv=venv}
  |  transDec(venv, tenv, A.TypeDec ({name, ty, pos}::decs)) =
      let
        val ty = case ty 
          of A.NameTy (sym, pos) => T.NAME (sym, ref NONE) (* TODO: Later, somewhere, update this ref *)
           | A.RecordTy fields => T.RECORD ([(*TODO fields *)], ref ()) (* TODO: convert field *)
           | A.ArrayTy (sym, pos) => T.ARRAY (lookupTy(pos, tenv, sym), ref ())
      in
        transDec(venv, S.enter(tenv, name, ty), A.TypeDec decs)
      end

  |  transDec(venv, tenv, A.FunctionDec[{name, params, body, pos, result=SOME(resTySy, resPos)}]) =
    (* TODO: Much left out here see MCI/ML p119 *)
    let
      val SOME(resTy) = S.look(tenv, resTySy)
      fun transParam {name, escape, typ, pos} =
        (* XXX: looks similar to lookupTy function *)
        case S.look(tenv, typ)
          of SOME t => {name=name, ty=t}
           | NONE   => (error pos ("Type '" ^ S.name typ ^ "' is not defined"); {name=name, ty=T.NIL})
      val params' = map transParam params (* map [ty] => [(name, ty)] *)
      val venv' = S.enter(venv, name, E.FunEntry {formals=map #ty params', result=resTy})
      fun enterParam({name, ty}, venv) =
        S.enter(venv, name, E.VarEntry {(*access=todoAccess,*) ty=ty})
      val venv'' = foldl enterParam venv' params'
          (* XXX: book had fold instead of foldl and I had to reverse the last two args. Should this be a foldr? *)
    in
      transExp(venv'', tenv, body);
      {venv=venv', tenv=tenv}
    end

  |  transDec(venv, tenv, A.FunctionDec[{name, params, body, pos, result=NONE}]) =
    (* TODO: Much left out here see MCI/ML p119 - FIXME: copy of above *)
    let
      val resTy = T.UNIT
      fun transParam {name, escape, typ, pos} =
        (* XXX: looks similar to lookupTy function *)
        case S.look(tenv, typ)
          of SOME t => {name=name, ty=t}
           | NONE   => (error pos ("Type '" ^ S.name typ ^ "' is not defined"); {name=name, ty=T.NIL})
      val params' = map transParam params (* map [ty] => [(name, ty)] *)
      val venv' = S.enter(venv, name, E.FunEntry {formals=map #ty params', result=resTy})
      fun enterParam({name, ty}, venv) =
        S.enter(venv, name, E.VarEntry {(*access=todoAccess,*) ty=ty})
      val venv'' = foldl enterParam venv' params'
          (* XXX: book had fold instead of foldl and I had to reverse the last two args. Should this be a foldr? *)
    in
      transExp(venv'', tenv, body);
      {venv=venv', tenv=tenv}
    end

  and transDecs(venv, tenv, []) = {venv=venv, tenv=tenv}
    | transDecs(venv, tenv, dec::decs) =
      let val {tenv=tenv', venv=venv'} = transDec(venv, tenv, dec)
      in transDecs(venv', tenv', decs)
      end

  and transExp(venv, tenv, exp) =
    let
      fun trexp(A.NilExp) = {exp=todoTrExp, ty=T.NIL}

        | trexp(A.VarExp var) = {exp=todoTrExp, ty=findVarType(tenv, venv, var)}

        | trexp(A.AssignExp {var, exp, pos}) =
          let
            val expA = trexp exp
            val varTy = findVarType(tenv, venv, var)
          in
            reqSameType(pos, tenv, {exp=(), ty=varTy}, expA);
            {exp=todoTrExp, ty=T.UNIT}
          end

        | trexp(A.ArrayExp {typ=tySymbol, size=sizeExp, init=initExp, pos}) =
          let
            val recordTy = lookupTy(pos, tenv, tySymbol)
            val sizeA = trexp sizeExp
            val initA = trexp initExp
          in
            checkInt(sizeA, pos);
            case recordTy
              of T.ARRAY (ty, unique) =>
                  (reqSameType(pos, tenv, {exp=(), ty=ty}, initA);
                   {exp=todoTrExp, ty=recordTy})
               | _ => (error pos "type is not an array";
                      {exp=todoTrExp, ty=T.UNIT})
          end

        | trexp(A.ForExp {var=varSym, escape, lo, hi, body, pos}) =
          let
            val loA = trexp lo
            val hiA = trexp hi
            val bodyA = trexp body
          in
            (* FIXME: Introduce the varSym variable *)
            checkInt(loA, pos);
            checkInt(hiA, pos);
            checkUnit(bodyA, pos);
            {exp=todoTrExp, ty=T.UNIT}
          end

        | trexp(A.WhileExp {test=testExp, body=bodyExp, pos}) =
          let
            val testA = trexp testExp
            val bodyA = trexp bodyExp
          in
            checkInt(testA, pos);
            checkUnit(bodyA, pos);
            {exp=todoTrExp, ty=T.UNIT}
          end

        | trexp(A.CallExp {func, args, pos}) =
          let
          in
            case S.look(venv, func)
              of SOME(E.VarEntry _) => (error pos "Variable is not a function"; errorExpTy)
               | NONE => (error pos "Function does not exist"; errorExpTy)
               | SOME(E.FunEntry {formals, result=resTy}) =>
                  let
                    val formalsN = length formals
                    val actualsN = length args
                  in
                    if formalsN <> actualsN then
                      (error pos "Function has the wrong arity"; errorExpTy)
                    else
                      let
                        val z = ListPair.zip (args, formals)
                        fun checkType(argExp, fTy) = reqSameType(pos, tenv, trexp argExp, {exp=(), ty=fTy})
                      in
                        (* check the type of each argument expression matches the corresponding formal parameter type *)
                        app checkType z;
                        {exp=todoTrExp, ty=resTy}
                      end
                  end
          end

        | trexp(A.IfExp {test=testExp, then'=thenExp, else'=SOME elseExp, pos}) =
          let
            val testA = trexp testExp
            val thenA = trexp thenExp
            val elseA = trexp elseExp
            val {exp=_, ty=resTy} = thenA
          in
            checkInt(testA, pos);
            reqSameType(pos, tenv, thenA, elseA);
            {exp=todoTrExp, ty=resTy}
          end

        | trexp(A.IfExp {test=testExp, then'=thenExp, else'=NONE, pos}) =
          let
            val testA = trexp testExp
            val thenA = trexp thenExp
            val {exp=_, ty=resTy} = thenA
          in
            checkInt(testA, pos);
            checkUnit(thenA, pos);
            {exp=todoTrExp, ty=T.UNIT}
          end

        | trexp(A.RecordExp {fields, typ, pos}) = 
          (
            (* TODO check fields match record type *)
            case S.look(tenv, typ) 
              of SOME t => {exp=todoTrExp, ty=t}
              |  NONE   => (error pos "record type does not exist"; {exp=todoTrExp, ty=T.NIL})
          )

        | trexp(A.IntExp _) = {exp=todoTrExp, ty=T.INT}
        | trexp(A.StringExp _) = {exp=todoTrExp, ty=T.STRING}
        | trexp(A.BreakExp pos) = {exp=todoTrExp, ty=T.UNIT}

        | trexp(A.OpExp{left, oper, right, pos}) =
          let val leftA = trexp left
              val rightA = trexp right
              val {exp=_, ty=leftTy} = leftA
              val {exp=_, ty=rightTy} = rightA
          in
            case leftTy
              (* FIXME: This record = nil thing is only for = and <> *)
              of T.RECORD _ => (if rightTy <> T.NIL then error pos "must be nil" else ();(* TODO how to records compare *)
                                {exp=todoTrExp, ty=leftTy})
                                
              (* TODO: insert logic for comparing arrays *)
              | _ => (
                     checkInt(leftA, pos);
                     checkInt(rightA, pos);
                     {exp=todoTrExp, ty=T.INT}
                   )
          end

        | trexp(A.LetExp {decs, body, pos}) =
            let val {venv=venv', tenv=tenv'} = transDecs(venv, tenv, decs)
            in transExp(venv', tenv', body) (* book has transExp(venv', tenv') body *)
            end
        | trexp(A.SeqExp expList) = 
            let 
              val rs = map trexp (map #1 expList)
              val {exp=_, ty=lastTy} = last rs
            in {exp=todoTrExp, ty=lastTy}
            end
            
      and trvar(A.SimpleVar(id, pos)) =
        (case S.look(venv, id)
          of SOME(E.VarEntry {ty}) => {exp=todoTrExp, ty=actualTy(pos, tenv, ty)}
           | SOME(E.FunEntry _)    => (error pos ("variable points to a function - compiler bug?: " ^ S.name id);
                                       {exp=errorTrExp, ty=T.INT})
           | NONE                  => (error pos ("undefined variable " ^ S.name id);
                                       {exp=errorTrExp, ty=T.INT})
        )
        | trvar(A.FieldVar(var, sym, pos)) = todoExpTy
        | trvar(A.SubscriptVar(var, exp, pos)) = todoExpTy
    in
      trexp(exp)
    end

  and transTy (            tenv: E.tenv, ty: A.ty): T.ty = todoTy

  and transProg(exp: A.exp):unit =
    (transExp(E.base_venv, E.base_tenv, exp);
     ())

end

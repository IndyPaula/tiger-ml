functor Translate(Frame: FRAME):
sig
  type level
  type access

  val outermostLevel: level
  val globalAccess: access

  val newLevel: { parent: level, name: Temp.label, formals: bool list } -> level
  val formals: level -> access list
  val allocLocal: level -> bool -> access

  type exp

  val unEx: exp -> Tree.exp
  val unNx: exp -> Tree.stm
  val unCx: exp -> (Temp.label * Temp.label -> Tree.stm)

  val simpleVar: access -> level -> exp
  val literalString: string -> exp
  val constantInt: int -> exp
  val nil: unit -> exp

  val procEntryExit: {level: level, body: exp} -> unit

  val getResult: unit -> Frame.frag list

  val todoExp: exp
end =
struct

  structure T = Tree

  val fragList: Frame.frag list ref = ref []

  datatype level
    = Level of {
        parent: level,
        name: Temp.label,
        formals: bool list,
        frame: Frame.frame,
        id: unit ref
      }
    | Outermost

  datatype access
    = Global
    | Local of level * Frame.access

  val outermostLevel = Outermost

  val globalAccess = Global

  fun newLevel({parent=parent, name=name, formals=formals}) =
    Level {parent=parent, name=name, 
           formals=formals, 
           frame=Frame.newFrame({name=Temp.newLabel(), formals=formals}),
           id = ref ()}

  fun formals level = case level
    of Outermost => raise Fail "no formals for outermost"
    | Level({parent=_,name=_,formals=formals,frame=_, id=_}) => [] (* TODO *)

  fun allocLocal level escapes = case level
    of Outermost => raise Fail "cannot allocate locals at outermost level"
    | Level {parent=_, name=_, formals=_, frame=frame, id=_} => 
        Local (level, Frame.allocLocal frame escapes)

  datatype exp
    = Ex of T.exp
    | Nx of T.stm
    | Cx of Temp.label * Temp.label -> T.stm

  val todoExp = Ex (Tree.CONST ~1)

  fun unEx (Ex e) = e
    | unEx (Cx mkStm) =
        let 
          val r = Temp.newTemp ()
          val t = Temp.newLabel ()
          val f = Temp.newLabel ()
        in
          T.ESEQ(T.seq[T.MOVE(T.TEMP r, T.CONST 1),
                       mkStm (t, f),
                       T.LABEL f,
                       T.MOVE (T.TEMP r, T.CONST 0),
                       T.LABEL t],
                 T.TEMP r)
        end
    | unEx (Nx s) = T.ESEQ (s, T.CONST 0)

  fun unNx (Ex exp) = T.EXP exp
(*  
  fun unNx (Nx stm) = Nx stm
*)

  fun unCx (Cx mkStm) = mkStm
  fun unCx (Ex e) = case e
    of (T.CONST 0) => fn (t, f) => T.EXP e
(*
     | (T.CONST 1) => fn (t, f) => T.EXP e
*)

  (* TODO: Handle following static links when levels are different. *)
  fun simpleVar (Local (localLevel, localAccess)) level = Ex (Frame.exp localAccess (T.TEMP Frame.FP))
  fun literalString literal = 
    let 
      val label = Temp.newLabel()
    in
      fragList := Frame.STRING (label, literal) :: !fragList;
      Ex (T.NAME label) (* TODO put string literal to frags *)
    end
  fun constantInt n = Ex (T.CONST n)
  fun nil () = Ex (T.MEM (T.CONST 0))

(*
  val procEntryExit: {level: level, body: exp} -> unit
*)

  fun procEntryExit {level: level, body: exp} = case level 
    of Outermost => raise Fail "procEntryExit doesn't cope with Outermost level"
     | Level({parent=_, name=_, formals=formals, frame, id=_}) =>
         let in
           fragList := Frame.PROC {body = unNx body, frame=frame} :: !fragList
         end

  fun getResult () = !fragList
end

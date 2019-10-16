(* *****************************************************************************
 * Seqaml.Ast: AST types and functions
 *
 * Author: inumanag
 * License: see LICENSE
 * *****************************************************************************)

open Core
open Util
open Ast_ann
open Option.Monad_infix

(** This module unifies all AST modules and extends them with
    various utility functions. *)

(** Alias for [Ast_ann]. Adds [to_string]. *)
module Ann = struct
  include Ast_ann

  let pos_to_string t =
    sprintf "%s:%d:%d" (Filename.basename t.file) t.line t.col

  let rec var_to_string ?(generics = Int.Table.create ()) ?(full=false) t =
    let f = var_to_string ~generics ~full in
    let gen2str g = ppl ~sep:"," g ~f:(fun (_, (g, t)) -> sprintf "%s" (f t)) in
    match t with
    | Tuple args ->
      sprintf "tuple[%s]" (ppl ~sep:"," args ~f)
    | Func ({ generics; args; _ }, { ret; used }) ->
      let g = gen2str generics in
      sprintf
        "function%s((%s),%s)"
        (if g = "" then "" else sprintf "[%s]" g)
        (ppl ~sep:"," (List.filter args ~f:(fun (n, _) -> not (Hash_set.exists used ~f:((=)n)) ))
          ~f:(fun (_, t) -> f t))
        (f ret)
    | Class ({ name; generics; _ }, _) ->
      let g = gen2str generics in
      sprintf "%s%s" name @@
        if g = "" then "" else sprintf "[%s]" g
    | Link { contents = Unbound (u, _, _) } ->
      if full then sprintf "'%d" u else "?"
    | Link { contents = Bound t } ->
      if full then sprintf "^%s" @@ f t else f t
    | Link { contents = Generic u } ->
      sprintf
        "T%d"
        (match Hashtbl.find generics u with
        | Some s -> s
        | None ->
          let w = succ @@ Hashtbl.length generics in
          Hashtbl.set generics ~key:u ~data:w;
          w)

  let typ_to_string ?(full=false) = function
    | Import s -> sprintf "<import: %s>" s
    | Type t
    | Var t -> var_to_string ~full t

  let t_to_string ?(full=false) = function
    | None -> "_"
    | Some s -> typ_to_string ~full s

  let to_string t =
    sprintf "<%s |= %s>" (pos_to_string t.pos) (t_to_string t.typ)

  let create ?(file="") ?(line=(-1)) ?(col=(-1)) ?(len=0) ?typ () =
    { pos = { file; line; col; len } ; typ }

  let rec real_type = function
    | Link { contents = Bound t } -> real_type t
    | t -> t

  let is_type = function
    | { typ = Some (Type _) ; _ } -> true
    | _ -> false

  let patch t f =
    match t.typ with
    | Some (Type _) -> { t with typ = Some (Type f) }
    | Some (Var _) -> { t with typ = Some (Var f) }
    | _ -> t

  let rec has_unbound ?(count_generics=false) t =
    let f = has_unbound ~count_generics in
    match t with
    | Link { contents = Unbound _ } -> true
    | Link { contents = Bound t } -> f t
    | Link { contents = Generic _ } -> count_generics
    | Tuple el -> List.exists el ~f
    | Class ({ generics; _ }, _) ->
      List.exists generics ~f:(fun (_, (_, t)) -> f t)
    | Func ({ generics; args; _ }, { ret; _ }) ->
      (List.exists generics ~f:(fun (_, (_, t)) -> f t)) ||
      (List.exists args ~f:(fun (_, t) -> f t)) ||
      f ret

  let is_realizable t =
    let f = has_unbound ~count_generics:true in
    not (match t with
    | Func ({ generics; args; _ }, { ret; _ }) ->
      (List.exists generics ~f:(fun (_, (_, t)) -> f t)) ||
      (List.exists args ~f:(fun (_, t) -> f t)) ||
      f ret
    | Class ({ generics; _ }, _) ->
      List.exists generics ~f:(fun (_, (_, t)) -> f t)
    | Tuple el -> List.exists el ~f
    | _ -> true)

  let var_of_typ t =
    match t with
    | None | Some (Import _) -> None
    | Some (Type t | Var t) -> Some t

  let var_of_typ_exn t =
    match var_of_typ t with Some s -> s | None -> failwith "invalid type"
end


(** Alias for [Ast_expr]. Adds [to_string]. *)
module Expr = struct
  include Ast_expr

  let rec to_string (enode : t ann) =
    match snd enode with
    | Empty _ -> ""
    | Ellipsis _ -> "..."
    | Bool x -> if x then "True" else "False"
    | Int x -> sprintf "%s" x
    | IntS (x, k) -> sprintf "%s%s" x k
    | Float x -> sprintf "%f" x
    | FloatS (x, k) -> sprintf "%f%s" x k
    | String x -> sprintf "'%s'" (String.escaped x)
    | Kmer x -> sprintf "k'%s'" x
    | Seq x -> sprintf "s'%s'" x
    | Id x -> sprintf "%s" x
    | Unpack x -> sprintf "*%s" x
    | Tuple l -> sprintf "(%s)" (ppl l ~f:to_string)
    | List l -> sprintf "[%s]" (ppl l ~f:to_string)
    | Set l -> sprintf "{%s}" (ppl l ~f:to_string)
    | Dict l ->
      sprintf "{%s}"
      @@ ppl l ~f:(fun (a, b) -> sprintf "%s: %s" (to_string a) (to_string b))
    | IfExpr (x, i, e) ->
      sprintf "%s if %s else %s" (to_string x) (to_string i) (to_string e)
    | Pipe l ->
      sprintf "%s" (ppl l ~sep:"" ~f:(fun (p, e) -> sprintf "%s %s" p @@ to_string e))
    | Binary (l, o, r) -> sprintf "(%s %s %s)" (to_string l) o (to_string r)
    | Unary (o, x) -> sprintf "(%s %s)" o (to_string x)
    | Index (x, l) -> sprintf "%s[%s]" (to_string x) (ppl l ~f:to_string)
    | Dot (x, s) -> sprintf "%s.%s" (to_string x) s
    | Call (x, l) -> sprintf "%s(%s)" (to_string x) (ppl l ~f:call_to_string)
    | TypeOf x -> sprintf "typeof(%s)" (to_string x)
    | Ptr x -> sprintf "ptr(%s)" (to_string x)
    | Slice (a, b, c) ->
      let l = List.map [ a; b; c ] ~f:(Option.value_map ~default:"" ~f:to_string) in
      sprintf "%s" (ppl l ~sep:":" ~f:Fn.id)
    | Generator (x, c) -> sprintf "(%s %s)" (to_string x) (comprehension_to_string c)
    | ListGenerator (x, c) -> sprintf "[%s %s]" (to_string x) (comprehension_to_string c)
    | SetGenerator (x, c) -> sprintf "{%s %s}" (to_string x) (comprehension_to_string c)
    | DictGenerator ((x1, x2), c) ->
      sprintf "{%s: %s %s}" (to_string x1) (to_string x2) (comprehension_to_string c)
    | Lambda (l, x) -> sprintf "lambda (%s): %s" (ppl l ~f:Fn.id) (to_string x)

  and call_to_string { name; value } =
    sprintf
      "%s%s"
      (Option.value_map name ~default:"" ~f:(fun x -> x ^ " = "))
      (to_string value)

  and comprehension_to_string { var; gen; cond; next } =
    sprintf
      "for %s in %s%s%s"
      (ppl var ~f:Fn.id)
      (to_string gen)
      (Option.value_map cond ~default:"" ~f:(fun x -> sprintf "if %s" (to_string x)))
      (Option.value_map next ~default:"" ~f:(fun x -> " " ^ comprehension_to_string x))




  (** [walk ~f expr] walks through an AST node [expr] and calls
      [f expr] on each child that potentially contains an identifier [Id].
      Useful for locating all captured variables within [expr]. *)
  let rec walk ~f (pos, node) =
    let walk = walk ~f in
    let rec fg { var; gen; cond; next } =
      { var; gen = walk gen; cond = cond >>| walk; next = next >>| fg }
    in
    f (pos, match node with
      | Tuple l -> Tuple (List.map l ~f:walk)
      | List l -> List (List.map l ~f:walk)
      | Set l -> Set (List.map l ~f:walk)
      | Dict l -> Dict (List.map l ~f:(fun (x, y) -> walk x, walk y))
      | Generator (g, tc) -> Generator (walk g, fg tc)
      | ListGenerator (g, tc) -> ListGenerator (walk g, fg tc)
      | SetGenerator (g, tc) -> SetGenerator (walk g, fg tc)
      | DictGenerator ((g1, g2), tc) -> DictGenerator (((walk g1), (walk g2)), fg tc)
      | IfExpr (a, b, c) -> IfExpr (walk a, walk b, walk c)
      | Unary (s, e) -> Unary (s, walk e)
      | Binary (e1, s, e2) -> Binary (walk e1, s, walk e2)
      | Pipe l -> Pipe (List.map l ~f:(fun (s, e) -> s, walk e))
      | Index (l, r) -> Index (walk l, List.map r ~f:walk)
      | Call (t, l) -> Call (walk t, List.map l
          ~f:(fun { name; value } -> { name; value = walk value }))
      | Slice (a, b, c) -> Slice (a >>| walk, b >>| walk, c >>| walk)
      | Dot (a, s) -> Dot (walk a, s)
      | TypeOf t -> TypeOf (walk t)
      | Ptr t -> Ptr (walk t)
      | Lambda (l, t) -> Lambda (l, walk t)
      | node -> node)
end

(** Alias for [Ast_stmt]. Adds [to_string]. *)
module Stmt = struct
  include Ast_stmt

  let rec to_string ?(indent = 0) (snode : t ann) =
    let s =
      match snd snode with
      | Pass _ -> sprintf "PASS"
      | Break _ -> sprintf "BREAK"
      | Continue _ -> sprintf "CONTINUE"
      | Expr x -> Expr.to_string x
      | Assign (l, r, s, q) ->
        (match q with
        | Some q ->
          sprintf
            "%s : %s %s %s"
            (Expr.to_string l)
            (Expr.to_string q)
            (match s with
            | Shadow -> ":="
            | _ -> "=")
            (Expr.to_string r)
        | None ->
          sprintf
            "%s %s %s"
            (Expr.to_string l)
            (match s with
            | Shadow -> ":="
            | _ -> "=")
            (Expr.to_string r))
      | Print (x, n) ->
        sprintf "PRINT %s, %s" (ppl x ~f:Expr.to_string) (String.escaped n)
      | Del x -> sprintf "DEL %s" (Expr.to_string x)
      | Assert x -> sprintf "ASSERT %s" (Expr.to_string x)
      | Yield x -> sprintf "YIELD %s" (Option.value_map x ~default:"" ~f:Expr.to_string)
      | Return x ->
        sprintf "RETURN %s" (Option.value_map x ~default:"" ~f:Expr.to_string)
      | TypeAlias (x, l) -> sprintf "TYPE %s = %s" x (Expr.to_string l)
      | While (x, l) ->
        sprintf
          "WHILE %s:\n%s"
          (Expr.to_string x)
          (ppl l ~sep:"\n" ~f:(to_string ~indent:(indent + 1)))
      | For (v, x, l) ->
        sprintf
          "FOR %s IN %s:\n%s"
          (ppl v ~f:Fn.id)
          (Expr.to_string x)
          (ppl l ~sep:"\n" ~f:(to_string ~indent:(indent + 1)))
      | If l ->
        String.concat ~sep:"\n"
        @@ List.mapi l ~f:(fun i { cond; cond_stmts } ->
               let cond = Option.value_map cond ~default:"" ~f:Expr.to_string in
               let case =
                 if i = 0 then "IF " else if cond = "" then "ELSE" else "ELIF "
               in
               sprintf
                 "%s%s:\n%s"
                 case
                 cond
                 (ppl cond_stmts ~sep:"\n" ~f:(to_string ~indent:(indent + 1))))
      | Match (x, l) ->
        sprintf
          "MATCH %s:\n%s"
          (Expr.to_string x)
          (ppl l ~sep:"\n" ~f:(fun { pattern; case_stmts } ->
               sprintf
                 "case <?>:\n%s"
                 (ppl case_stmts ~sep:"\n" ~f:(to_string ~indent:(indent + 1)))))
      | _ -> "?"
    in
    let pad l = String.make (l * 2) ' ' in
    sprintf "%s%s" (pad indent) s

  and param_to_string (_, { name; typ }) =
    let typ = Option.value_map typ ~default:"" ~f:(fun x -> " : " ^ Expr.to_string x) in
    sprintf "%s%s" name typ

  (** [walk ~f expr] walks through an AST node [expr] and calls
      [f expr] on each child that potentially contains an identifier [Id].
      Useful for locating all captured variables within [expr]. *)
  let rec walk ~fe ~f (pos, node) =
    let walk = walk ~f ~fe in
    let ewalk = Expr.walk ~f:fe in
    let pwalk = fun { name; typ } -> { name; typ = typ >>| ewalk } in
    let rec mwalk = function
      | TuplePattern pl -> TuplePattern (List.map pl ~f:mwalk)
      | ListPattern pl -> ListPattern (List.map pl ~f:mwalk)
      | OrPattern pl -> OrPattern (List.map pl ~f:mwalk)
      | GuardedPattern (p, e) -> GuardedPattern (mwalk p, ewalk e)
      | BoundPattern (s, p) -> BoundPattern (s, mwalk p)
      | p -> p
    in
    f (pos, match node with
      | Expr s -> Expr (ewalk s)
      | Assign (l, r, a, t) -> Assign (ewalk l, ewalk r, a, t >>| ewalk)
      | Del t -> Del (ewalk t)
      | Print (l, s) -> Print (List.map l ~f:ewalk, s)
      | Return e -> Return (e >>| ewalk)
      | Yield e -> Yield (e >>| ewalk)
      | Assert e -> Assert (ewalk e)
      | TypeAlias (s, e) -> TypeAlias (s, ewalk e)
      | While (c, l) -> While (ewalk c, List.map l ~f:walk)
      | For (s, c, l) -> For (s, ewalk c, List.map l ~f:walk)
      | If l -> If (List.map l ~f:(fun { cond; cond_stmts } ->
          { cond = cond >>| ewalk; cond_stmts = List.map cond_stmts ~f:walk }))
      | Match (e, l) -> Match (ewalk e, List.map l ~f:(fun { pattern; case_stmts } ->
          { pattern = mwalk pattern; case_stmts = List.map case_stmts ~f:walk }))
      | Extend (e, gl) -> Extend(ewalk e, List.map gl ~f:walk)
      | Extern (a, b, c, p, pl) ->
        Extern (a, b, c, pwalk p, List.map pl ~f:pwalk)
      | Function f -> Function
        { f with fn_name = pwalk f.fn_name
        ; fn_args = List.map f.fn_args ~f:pwalk
        ; fn_stmts = List.map f.fn_stmts ~f:walk }
      | Class f -> Class
        { f with args = f.args >>| List.map ~f:pwalk
        ; members = List.map f.members ~f:walk }
      | Type f -> Type
        { f with args = f.args >>| List.map ~f:pwalk
        ; members = List.map f.members ~f:walk }
      | Declare p -> Declare (pwalk p)
      | Try (tl, cl, fl) ->
       (* of (t ann list * catch ann list * t ann list option) *)
        Try (List.map tl ~f:walk, List.map cl ~f:(fun e ->
          { e with exc = e.exc >>| ewalk
          ; stmts = List.map e.stmts ~f:walk}), fl >>| List.map ~f:walk)
      (** [Try(stmts, catch, finally_stmts)] corresponds to
      [try: stmts ... ; (catch1: ... ; catch2: ... ;) finally: finally_stmts ] *)
      | Throw e -> Throw (ewalk e)
      | Prefetch l -> Prefetch (List.map l ~f:ewalk)
      | Special (s, l, sl) -> Special (s, List.map l ~f:walk, sl)
      | Pass _ | Break _ | Continue _ | Import _ | ImportPaste _ | Global _ -> node
      )
end

let var_of_node n =
  Ann.var_of_typ (fst n).Ann.typ

let var_of_node_exn n =
  Ann.var_of_typ_exn (fst n).Ann.typ

let e_id ?(ann=default) n =
  ann, Expr.Id n

let e_int ?(ann=default) n =
  ann, Expr.Int (sprintf "%d" n)

let e_ellipsis ?(ann=default) () =
  ann, Expr.Ellipsis ()

let e_tuple ?(ann=default) args =
  ann, Expr.Tuple args

let e_call ?(ann=default) callee args =
  ann, Expr.(Call (callee,
    List.map args ~f:(fun value -> { name = None; value })))

let e_index ?(ann=default) collection args =
  ann, Expr.Index (collection, args)

let e_dot ?(ann=default) left what =
  ann, Expr.Dot (left, what)

let e_typeof ?(ann=default) what =
  ann, Expr.TypeOf what

let s_expr ?(ann=default) expr =
  ann, Stmt.Expr expr

let s_assign ?(ann=default) lhs rhs =
  ann, Stmt.(Assign (rhs, rhs, Normal, None))

let s_if ?(ann=default) cond stmts =
  ann, Stmt.(If [ { cond = Some cond; cond_stmts = stmts } ])

let s_for ?(ann=default) vars iter stmts =
  ann, Stmt.For (vars, iter, stmts)

let s_extern ?(ann=default) ?(lang="c") name ret params =
  ann, Stmt.Extern
    ( lang
    , None
    , name
    , { name = name; typ = Some ret }
    , List.map params ~f:(fun (name, typ) -> Stmt.{ name; typ = Some typ })
    )

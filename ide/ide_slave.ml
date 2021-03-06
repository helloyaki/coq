(************************************************************************)

(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Vernacexpr
open Vernacprop
open CErrors
open Util
open Pp
open Printer

module RelDecl = Context.Rel.Declaration
module NamedDecl = Context.Named.Declaration
module CompactedDecl = Context.Compacted.Declaration

(** Ide_slave : an implementation of [Interface], i.e. mainly an interp
    function and a rewind function. This specialized loop is triggered
    when the -ideslave option is passed to Coqtop. Currently CoqIDE is
    the only one using this mode, but we try here to be as generic as
    possible, so this may change in the future... *)

(** Signal handling: we postpone ^C during input and output phases,
    but make it directly raise a Sys.Break during evaluation of the request. *)

let catch_break = ref false

let init_signal_handler () =
  let f _ = if !catch_break then raise Sys.Break else Control.interrupt := true in
  Sys.set_signal Sys.sigint (Sys.Signal_handle f)

let pr_with_pid s = Printf.eprintf "[pid %d] %s\n%!" (Unix.getpid ()) s

let pr_error s = pr_with_pid s
let pr_debug s =
  if !Flags.debug then pr_with_pid s
let pr_debug_call q =
  if !Flags.debug then pr_with_pid ("<-- " ^ Xmlprotocol.pr_call q)
let pr_debug_answer q r =
  if !Flags.debug then pr_with_pid ("--> " ^ Xmlprotocol.pr_full_value q r)

(** Categories of commands *)

let coqide_known_option table = List.mem table [
  ["Printing";"Implicit"];
  ["Printing";"Coercions"];
  ["Printing";"Matching"];
  ["Printing";"Synth"];
  ["Printing";"Notations"];
  ["Printing";"All"];
  ["Printing";"Records"];
  ["Printing";"Existential";"Instances"];
  ["Printing";"Universes"]]

let is_known_option cmd = match cmd with
  | VernacSetOption (o,BoolValue true)
  | VernacUnsetOption o -> coqide_known_option o
  | _ -> false

(** Check whether a command is forbidden in the IDE *)

let ide_cmd_checks (loc,ast) =
  let user_error s = CErrors.user_err ~loc ~hdr:"CoqIde" (str s) in
  if is_debug ast then
    user_error "Debug mode not available in the IDE";
  if is_known_option ast then
    Feedback.msg_warning ~loc (strbrk "Set this option from the IDE menu instead");
  if is_navigation_vernac ast || is_undo ast then
    Feedback.msg_warning ~loc (strbrk "Use IDE navigation instead");
  if is_query ast then
    Feedback.msg_warning ~loc (strbrk "Query commands should not be inserted in scripts")

(** Interpretation (cf. [Ide_intf.interp]) *)

let add ((s,eid),(sid,verbose)) =
  let pa = Pcoq.Gram.parsable (Stream.of_string s) in
  let loc_ast = Stm.parse_sentence sid pa in
  ide_cmd_checks loc_ast;
  let newid, rc = Stm.add ~ontop:sid verbose loc_ast in
  let rc = match rc with `NewTip -> CSig.Inl () | `Unfocus id -> CSig.Inr id in
  (* TODO: the "" parameter is a leftover of the times the protocol
   * used to include stderr/stdout output.
   *
   * Currently, we force all the output meant for the to go via the
   * feedback mechanism, and we don't manipulate stderr/stdout, which
   * are left to the client's discrection. The parameter is still there
   * as not to break the core protocol for this minor change, but it should
   * be removed in the next version of the protocol.
   *)
  newid, (rc, "")

let edit_at id =
  match Stm.edit_at id with
  | `NewTip -> CSig.Inl ()
  | `Focus { Stm.start; stop; tip} -> CSig.Inr (start, (stop, tip))

(* TODO: the "" parameter is a leftover of the times the protocol
 * used to include stderr/stdout output.
 *
 * Currently, we force all the output meant for the to go via the
 * feedback mechanism, and we don't manipulate stderr/stdout, which
 * are left to the client's discrection. The parameter is still there
 * as not to break the core protocol for this minor change, but it should
 * be removed in the next version of the protocol.
 *)
let query (s,id) =
  let pa = Pcoq.Gram.parsable (Stream.of_string s) in
  Stm.query ~at:id pa; ""

let annotate phrase =
  let (loc, ast) =
    let pa = Pcoq.Gram.parsable (Stream.of_string phrase) in
    Stm.parse_sentence (Stm.get_current_state ()) pa
  in
  (* XXX: Width should be a parameter of annotate... *)
  Richpp.richpp_of_pp 78 (Ppvernac.pr_vernac ast)

(** Goal display *)

let hyp_next_tac sigma env decl =
  let id = NamedDecl.get_id decl in
  let ast = NamedDecl.get_type decl in
  let id_s = Names.Id.to_string id in
  let type_s = string_of_ppcmds (pr_ltype_env env sigma ast) in
  [
    ("clear "^id_s),("clear "^id_s^".");
    ("apply "^id_s),("apply "^id_s^".");
    ("exact "^id_s),("exact "^id_s^".");
    ("generalize "^id_s),("generalize "^id_s^".");
    ("absurd <"^id_s^">"),("absurd "^type_s^".")
  ] @ [
    ("discriminate "^id_s),("discriminate "^id_s^".");
    ("injection "^id_s),("injection "^id_s^".")
  ] @ [
    ("rewrite "^id_s),("rewrite "^id_s^".");
    ("rewrite <- "^id_s),("rewrite <- "^id_s^".")
  ] @ [
    ("elim "^id_s), ("elim "^id_s^".");
    ("inversion "^id_s), ("inversion "^id_s^".");
    ("inversion clear "^id_s), ("inversion_clear "^id_s^".")
  ]

let concl_next_tac sigma concl =
  let expand s = (s,s^".") in
  List.map expand ([
    "intro";
    "intros";
    "intuition"
  ] @ [
    "reflexivity";
    "discriminate";
    "symmetry"
  ] @ [
    "assumption";
    "omega";
    "ring";
    "auto";
    "eauto";
    "tauto";
    "trivial";
    "decide equality";
    "simpl";
    "subst";
    "red";
    "split";
    "left";
    "right"
  ])

let process_goal sigma g =
  let env = Goal.V82.env sigma g in
  let min_env = Environ.reset_context env in
  let id = Goal.uid g in
  let ccl =
    let norm_constr = Reductionops.nf_evar sigma (Goal.V82.concl sigma g) in
    pr_goal_concl_style_env env sigma norm_constr
  in
  let process_hyp d (env,l) =
    let d = CompactedDecl.map_constr (fun c -> EConstr.Unsafe.to_constr (Reductionops.nf_evar sigma (EConstr.of_constr c))) d in
    let d' = CompactedDecl.to_named_context d in
      (List.fold_right Environ.push_named d' env,
       (pr_compacted_decl env sigma d) :: l) in
  let (_env, hyps) =
    Context.Compacted.fold process_hyp
      (Termops.compact_named_context (Environ.named_context env)) ~init:(min_env,[]) in
  { Interface.goal_hyp = List.rev hyps; Interface.goal_ccl = ccl; Interface.goal_id = id; }

let export_pre_goals pgs =
  {
    Interface.fg_goals       = pgs.Proof.fg_goals;
    Interface.bg_goals       = pgs.Proof.bg_goals;
    Interface.shelved_goals  = pgs.Proof.shelved_goals;
    Interface.given_up_goals = pgs.Proof.given_up_goals
  }

let goals () =
  Stm.finish ();
  try
    let pfts = Proof_global.give_me_the_proof () in
    Some (export_pre_goals (Proof.map_structured_proof pfts process_goal))
  with Proof_global.NoCurrentProof -> None

let evars () =
  try
    Stm.finish ();
    let pfts = Proof_global.give_me_the_proof () in
    let { Evd.it = all_goals ; sigma = sigma } = Proof.V82.subgoals pfts in
    let exl = Evar.Map.bindings (Evarutil.non_instantiated sigma) in
    let map_evar ev = { Interface.evar_info = string_of_ppcmds (pr_evar sigma ev); } in
    let el = List.map map_evar exl in
    Some el
  with Proof_global.NoCurrentProof -> None

let hints () =
  try
    let pfts = Proof_global.give_me_the_proof () in
    let { Evd.it = all_goals ; sigma = sigma } = Proof.V82.subgoals pfts in
    match all_goals with
    | [] -> None
    | g :: _ ->
      let env = Goal.V82.env sigma g in
      let hint_goal = concl_next_tac sigma g in
      let get_hint_hyp env d accu = hyp_next_tac sigma env d :: accu in
      let hint_hyps = List.rev (Environ.fold_named_context get_hint_hyp env ~init: []) in
      Some (hint_hyps, hint_goal)
  with Proof_global.NoCurrentProof -> None


(** Other API calls *)

let status force =
  (** We remove the initial part of the current [DirPath.t]
      (usually Top in an interactive session, cf "coqtop -top"),
      and display the other parts (opened sections and modules) *)
  Stm.finish ();
  if force then Stm.join ();
  let path =
    let l = Names.DirPath.repr (Lib.cwd ()) in
    List.rev_map Names.Id.to_string l
  in
  let proof =
    try Some (Names.Id.to_string (Proof_global.get_current_proof_name ()))
    with Proof_global.NoCurrentProof -> None
  in
  let allproofs =
    let l = Proof_global.get_all_proof_names () in
    List.map Names.Id.to_string l
  in
  {
    Interface.status_path = path;
    Interface.status_proofname = proof;
    Interface.status_allproofs = allproofs;
    Interface.status_proofnum = Stm.current_proof_depth ();
  }

let export_coq_object t = {
  Interface.coq_object_prefix = t.Search.coq_object_prefix;
  Interface.coq_object_qualid = t.Search.coq_object_qualid;
  Interface.coq_object_object = Pp.string_of_ppcmds (pr_lconstr_env (Global.env ()) Evd.empty t.Search.coq_object_object)
}

let pattern_of_string ?env s =
  let env =
    match env with
    | None -> Global.env ()
    | Some e -> e
  in
  let constr = Pcoq.parse_string Pcoq.Constr.lconstr_pattern s in
  let (_, pat) = Constrintern.intern_constr_pattern env constr in
  pat

let dirpath_of_string_list s =
  let path = String.concat "." s in
  let m = Pcoq.parse_string Pcoq.Constr.global path in
  let (_, qid) = Libnames.qualid_of_reference m in
  let id =
    try Nametab.full_name_module qid
    with Not_found ->
      CErrors.user_err ~hdr:"Search.interface_search"
        (str "Module " ++ str path ++ str " not found.")
  in
  id

let import_search_constraint = function
  | Interface.Name_Pattern s    -> Search.Name_Pattern (Str.regexp s)
  | Interface.Type_Pattern s    -> Search.Type_Pattern (pattern_of_string s)
  | Interface.SubType_Pattern s -> Search.SubType_Pattern (pattern_of_string s)
  | Interface.In_Module ms      -> Search.In_Module (dirpath_of_string_list ms)
  | Interface.Include_Blacklist -> Search.Include_Blacklist

let search flags =
  List.map export_coq_object (Search.interface_search (
    List.map (fun (c, b) -> (import_search_constraint c, b)) flags)
  )

let export_option_value = function
  | Goptions.BoolValue b   -> Interface.BoolValue b
  | Goptions.IntValue x    -> Interface.IntValue x
  | Goptions.StringValue s -> Interface.StringValue s
  | Goptions.StringOptValue s -> Interface.StringOptValue s

let import_option_value = function
  | Interface.BoolValue b   -> Goptions.BoolValue b
  | Interface.IntValue x    -> Goptions.IntValue x
  | Interface.StringValue s -> Goptions.StringValue s
  | Interface.StringOptValue s -> Goptions.StringOptValue s

let export_option_state s = {
  Interface.opt_sync  = s.Goptions.opt_sync;
  Interface.opt_depr  = s.Goptions.opt_depr;
  Interface.opt_name  = s.Goptions.opt_name;
  Interface.opt_value = export_option_value s.Goptions.opt_value;
}

let get_options () =
  let table = Goptions.get_tables () in
  let fold key state accu = (key, export_option_state state) :: accu in
  Goptions.OptionMap.fold fold table []

let set_options options =
  let iter (name, value) = match import_option_value value with
  | BoolValue b -> Goptions.set_bool_option_value name b
  | IntValue i -> Goptions.set_int_option_value name i
  | StringValue s -> Goptions.set_string_option_value name s
  | StringOptValue (Some s) -> Goptions.set_string_option_value name s
  | StringOptValue None -> Goptions.unset_option_value_gen None name
  in
  List.iter iter options

let about () = {
  Interface.coqtop_version = Coq_config.version;
  Interface.protocol_version = Xmlprotocol.protocol_version;
  Interface.release_date = Coq_config.date;
  Interface.compile_date = Coq_config.compile_date;
}

let handle_exn (e, info) =
  let dummy = Stateid.dummy in
  let loc_of e = match Loc.get_loc e with
    | Some loc when not (Loc.is_ghost loc) -> Some (Loc.unloc loc)
    | _ -> None in
  let mk_msg () = CErrors.print ~info e in
  match e with
  | CErrors.Drop -> dummy, None, Pp.str "Drop is not allowed by coqide!"
  | CErrors.Quit -> dummy, None, Pp.str "Quit is not allowed by coqide!"
  | e ->
      match Stateid.get info with
      | Some (valid, _) -> valid, loc_of info, mk_msg ()
      | None -> dummy, loc_of info, mk_msg ()

let init =
  let initialized = ref false in
  fun file ->
   if !initialized then anomaly (str "Already initialized")
   else begin
     let init_sid = Stm.get_current_state () in
     initialized := true;
     match file with
     | None -> init_sid
     | Some file ->
         let dir = Filename.dirname file in
         let open Loadpath in let open CUnix in
         let initial_id, _ =
           if not (is_in_load_paths (physical_path_of_string dir)) then begin
             let pa = Pcoq.Gram.parsable (Stream.of_string (Printf.sprintf "Add LoadPath \"%s\". " dir)) in
             let loc_ast = Stm.parse_sentence init_sid pa in
             Stm.add false ~ontop:init_sid loc_ast
           end else init_sid, `NewTip in
         if Filename.check_suffix file ".v" then
           Stm.set_compilation_hints file;
         Stm.finish ();
         initial_id
   end

(* Retrocompatibility stuff, disabled since 8.7 *)
let interp ((_raw, verbose), s) =
  Stateid.dummy, CSig.Inr "The interp call has been disabled, please use Add."

(** When receiving the Quit call, we don't directly do an [exit 0],
    but rather set this reference, in order to send a final answer
    before exiting. *)

let quit = ref false

(** Serializes the output of Stm.get_ast  *)
let print_ast id =
  match Stm.get_ast id with
  | Some (expr, loc) -> begin
      try  Texmacspp.tmpp expr loc
      with e -> Xml_datatype.PCData ("ERROR " ^ Printexc.to_string e)
    end
  | None     -> Xml_datatype.PCData "ERROR"

(** Grouping all call handlers together + error handling *)

let eval_call c =
  let interruptible f x =
    catch_break := true;
    Control.check_for_interrupt ();
    let r = f x in
    catch_break := false;
    r
  in
  let handler = {
    Interface.add = interruptible add;
    Interface.edit_at = interruptible edit_at;
    Interface.query = interruptible query;
    Interface.goals = interruptible goals;
    Interface.evars = interruptible evars;
    Interface.hints = interruptible hints;
    Interface.status = interruptible status;
    Interface.search = interruptible search;
    Interface.get_options = interruptible get_options;
    Interface.set_options = interruptible set_options;
    Interface.mkcases = interruptible Vernacentries.make_cases;
    Interface.quit = (fun () -> quit := true);
    Interface.init = interruptible init;
    Interface.about = interruptible about;
    Interface.interp = interruptible interp;
    Interface.handle_exn = handle_exn;
    Interface.stop_worker = Stm.stop_worker;
    Interface.print_ast = print_ast;
    Interface.annotate = interruptible annotate;
  } in
  Xmlprotocol.abstract_eval_call handler c

(** Message dispatching.
    Since coqtop -ideslave starts 1 thread per slave, and each
    thread forwards feedback messages from the slave to the GUI on the same
    xml channel, we need mutual exclusion.  The mutex should be per-channel, but
    here we only use 1 channel. *)
let print_xml =
  let m = Mutex.create () in
  fun oc xml ->
    Mutex.lock m;
    try Xml_printer.print oc xml; Mutex.unlock m
    with e -> let e = CErrors.push e in Mutex.unlock m; iraise e

let slave_feeder fmt xml_oc msg =
  let xml = Xmlprotocol.(of_feedback fmt msg) in
  print_xml xml_oc xml

(** The main loop *)

(** Exceptions during eval_call should be converted into [Interface.Fail]
    messages by [handle_exn] above. Otherwise, we die badly, without
    trying to answer malformed requests. *)

let msg_format = ref (fun () ->
    let margin = Option.default 72 (Topfmt.get_margin ()) in
    Xmlprotocol.Richpp margin
)

let loop () =
  init_signal_handler ();
  catch_break := false;
  let in_ch, out_ch = Spawned.get_channels ()                        in
  let xml_oc        = Xml_printer.make (Xml_printer.TChannel out_ch) in
  let in_lb         = Lexing.from_function (fun s len ->
                      CThread.thread_friendly_read in_ch s ~off:0 ~len) in
  (* SEXP parser make *)
  let xml_ic        = Xml_parser.make (Xml_parser.SLexbuf in_lb) in
  let () = Xml_parser.check_eof xml_ic false in
  ignore (Feedback.add_feeder (slave_feeder (!msg_format ()) xml_oc));
  while not !quit do
    try
      let xml_query = Xml_parser.parse xml_ic in
(*       pr_with_pid (Xml_printer.to_string_fmt xml_query); *)
      let Xmlprotocol.Unknown q = Xmlprotocol.to_call xml_query in
      let () = pr_debug_call q in
      let r  = eval_call q in
      let () = pr_debug_answer q r in
(*       pr_with_pid (Xml_printer.to_string_fmt (Xmlprotocol.of_answer q r)); *)
      print_xml xml_oc Xmlprotocol.(of_answer (!msg_format ()) q r);
      flush out_ch
    with
      | Xml_parser.Error (Xml_parser.Empty, _) ->
        pr_debug "End of input, exiting gracefully.";
        exit 0
      | Xml_parser.Error (err, loc) ->
        pr_error ("XML syntax error: " ^ Xml_parser.error_msg err)
      | Serialize.Marshal_error (msg,node) ->
        pr_error "Unexpected XML message";
        pr_error ("Expected XML node: " ^ msg);
        pr_error ("XML tree received: " ^ Xml_printer.to_string_fmt node)
      | any ->
        pr_debug ("Fatal exception in coqtop:\n" ^ Printexc.to_string any);
        exit 1
  done;
  pr_debug "Exiting gracefully.";
  exit 0

let rec parse = function
  | "--help-XML-protocol" :: rest ->
        Xmlprotocol.document Xml_printer.to_string_fmt; exit 0
  | "--xml_format=Ppcmds" :: rest ->
        msg_format := (fun () -> Xmlprotocol.Ppcmds); parse rest
  | x :: rest -> x :: parse rest
  | [] -> []

let () = Coqtop.toploop_init := (fun args ->
        let args = parse args in
        Flags.make_silent true;
        CoqworkmgrApi.(init Flags.High);
        args)

let () = Coqtop.toploop_run := loop

let () = Usage.add_to_usage "coqidetop"
"  --xml_format=Ppcmds    serialize pretty printing messages using the std_ppcmds format
  --help-XML-protocol    print the documentation of the XML protocol used by CoqIDE\n"

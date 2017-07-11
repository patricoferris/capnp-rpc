module RO_array = Capnp_rpc.RO_array
module Test_utils = Testbed.Test_utils

let running_under_afl =
  match Array.to_list Sys.argv with
  | [] -> assert false
  | [_] -> false
  | [_; "--fuzz"] -> true
  | prog :: _ -> Capnp_rpc.Debug.failf "Usage: %s < input-data" prog

let three_vats = true

let stop_after =
  match Sys.getenv "FUZZ_STOP" with
  | s ->
    Fmt.epr "vi: foldmethod=marker syntax=capnp-rpc@.";
    int_of_string s
  | exception Not_found -> -1
(* If the ref-counting seems off after a while, try setting this to a low-ish number.
   This will cause it to try to clean up early and hopefully discover the problem sooner. *)

let dump_state_at_each_step = not running_under_afl

let sanity_checks = not running_under_afl
(* Check that the state is valid after every step (slow). *)

let () =
  if running_under_afl then (
    Logs.set_level ~all:true (Some Logs.Error);
  ) else (
    Printexc.record_backtrace true
  )

let failf msg = Fmt.kstrf failwith msg

let styles = [| `Red; `Green; `Blue |]

let actor_for_id id =
  let style = styles.(id mod Array.length styles) in
  (style, Fmt.strf "vat-%d" id)

let tags_for_id id =
  Logs.Tag.empty |> Logs.Tag.add Test_utils.actor_tag (actor_for_id id)

(* We want to check that messages sent over a reference arrive in order. *)
type cap_ref_counters = {
  mutable next_to_send : int;
  mutable next_expected : int;
}

let pp_counters f {next_to_send; next_expected} = Fmt.pf f "{send=%d; expect=%d}" next_to_send next_expected

module Msg = struct
  module Path = struct
    type t = int
    let compare = compare
    let pp = Fmt.int
    let root = 0
  end

  module Request = struct
    type t = {
      target : Direct.cap;
      seq : int;
      counters : cap_ref_counters;
      arg_ids : Direct.cap RO_array.t;
      answer : Direct.struct_ref;
    }
    let pp f {seq; counters; _} = Fmt.pf f "{seq=%d; cap_ref=%a}" seq pp_counters counters

    let cap_index _ i = Some i
  end

  module Response = struct
    type t = string
    let pp = Fmt.string
    let cap_index _ i = Some i
    let bootstrap = "(boot)"
  end

  let ref_leak_detected fn =
    fn ();
    failwith "ref_leak_detected"
end

module Core_types = struct
  include Capnp_rpc.Core_types(Msg)
  type sturdy_ref
  type provision_id
  type recipient_id
  type third_party_cap_id
  type join_key_part
end

module Local_struct_promise = Capnp_rpc.Local_struct_promise.Make(Core_types)

module EP = struct
  module Core_types = Core_types

  module Table = struct
    module QuestionId = Capnp_rpc.Id.Make ( )
    module AnswerId = QuestionId
    module ImportId = Capnp_rpc.Id.Make ( )
    module ExportId = ImportId
  end

  module Out = Capnp_rpc.Message_types.Make(Core_types)(Table)
  module In = Capnp_rpc.Message_types.Make(Core_types)(Table)
end

module Endpoint = struct
  module Conn = Capnp_rpc.CapTP.Make(EP)

  type t = {
    conn : Conn.t;
    recv_queue : EP.In.t Queue.t;
  }

  let dump f t =
    Conn.dump f t.conn

  let check t =
    Conn.check t.conn

  let create ?bootstrap ~tags xmit_queue recv_queue =
    let queue_send x = Queue.add x xmit_queue in
    let conn = Conn.create ?bootstrap ~tags ~queue_send in
    {
      conn;
      recv_queue;
    }

  let handle_msg t =
    match Queue.pop t.recv_queue with
    | exception Queue.Empty -> Alcotest.fail "No messages found!"
    | msg ->
      let tags = EP.In.with_qid_tag (Conn.tags t.conn) msg in
      Logs.info (fun f -> f ~tags "<- %a" (EP.In.pp_recv Msg.Request.pp) msg);
      Conn.handle_msg t.conn msg

  let maybe_handle_msg t =
    if Queue.length t.recv_queue > 0 then handle_msg t

  let bootstrap t = Conn.bootstrap t.conn

  let try_step t =
    if Queue.length t.recv_queue > 0 then (
      if dump_state_at_each_step then
        Logs.info (fun f -> f ~tags:(Conn.tags t.conn) "@[<v>{{{%a}}}@]" dump t);
      handle_msg t;
      if sanity_checks then Conn.check t.conn;
      true
    ) else false

  let disconnect t =
    Conn.disconnect t.conn (Capnp_rpc.Exception.v "Tests finished")
end

let () =
  Format.pp_set_margin Fmt.stderr 120;
  Fmt_tty.setup_std_outputs ()

let dummy_answer = object (self : Core_types.struct_resolver)
  method cap _ = failwith "dummy_answer"
  method connect x = x#finish
  method finish = failwith "dummy_answer"
  method pp f = Fmt.string f "dummy_answer"
  method resolve x = self#connect (Core_types.resolved x)
  method response = failwith "dummy_answer"
  method when_resolved _ = failwith "when_resolved"
  method blocker = None
  method check_invariants = ()
end

type cap_ref = {
  cr_cap : Core_types.cap;
  cr_target : Direct.cap;
  cr_counters : cap_ref_counters;
}

let make_cap_ref ~target cap =
  {
    cr_cap = cap;
    cr_target = target;
    cr_counters = { next_to_send = 0; next_expected = 0 };
  }

module Vat = struct
  type t = {
    id : int;
    mutable bootstrap : (Core_types.cap * Direct.cap) option;
    caps : cap_ref DynArray.t;
    structs : (Core_types.struct_ref * Direct.struct_ref) DynArray.t;
    actions : (unit -> unit) DynArray.t;
    mutable connections : (int * Endpoint.t) list;
    answers_needed : (Core_types.struct_resolver * Direct.struct_ref) DynArray.t;
  }

  let tags t = tags_for_id t.id

  let pp_error f cap =
    try cap#check_invariants
    with ex ->
      Fmt.pf f "@,[%a] %a"
        Fmt.(styled `Red string) "ERROR"
        Capnp_rpc.Debug.pp_exn ex

  let dump_cap f {cr_target; cr_cap; cr_counters} =
    Fmt.pf f "%a : @[%t %a;%a@]"
      Direct.pp cr_target
      cr_cap#pp
      pp_counters cr_counters
      pp_error cr_cap

  let dump_sr f (sr, target) =
    Fmt.pf f "%a : @[%t;%a@]"
      Direct.pp_struct target
      sr#pp
      pp_error sr

  let dump_an f (sr, target) =
    Fmt.pf f "%a : @[%t;%a@]"
      Direct.pp_struct target
      sr#pp
      pp_error sr

  let compare_cr a b =
    Direct.compare_cap a.cr_target b.cr_target

  let compare_sr (_, a) (_, b) =
    Direct.compare_sr a b

  let compare_an (_, a) (_, b) =
    Direct.compare_sr a b

  let pp f t =
    let pp_connection f (id, endpoint) =
      Fmt.pf f "@[<v2>Connection to %d@,%a\
                @[<v2>Caps:@,%a@]@,\
                @[<v2>Structs:@,%a@]@,\
                @[<v2>Answers waiting:@,%a@]@,\
                @]" id
        Endpoint.dump endpoint
        (DynArray.dump ~compare:compare_cr dump_cap) t.caps
        (DynArray.dump ~compare:compare_sr dump_sr) t.structs
        (DynArray.dump ~compare:compare_an dump_an) t.answers_needed
      ;
    in
    Fmt.Dump.list pp_connection f t.connections

  let check t =
    try
      t.connections |> List.iter (fun (_, conn) -> Endpoint.check conn);
      t.caps |> DynArray.iter (fun c -> c.cr_cap#check_invariants);
      t.structs |> DynArray.iter (fun (s, _) -> s#check_invariants);
      t.answers_needed |> DynArray.iter (fun (s, _) -> s#check_invariants)
    with ex ->
      Logs.err (fun f -> f ~tags:(tags t) "Invariants check failed: %a" Capnp_rpc.Debug.pp_exn ex);
      raise ex

  let do_action state =
    match DynArray.pick state.actions with
    | Some fn -> fn ()
    | None -> assert false        (* There should always be some actions *)

  let n_caps state n =
    let rec caps = function
      | 0 -> []
      | i ->
        match DynArray.pick state.caps with
        | Some c -> c :: caps (i - 1)
        | None -> []
    in
    let cap_refs = caps n in
    let args = RO_array.of_list @@ List.map (fun cr -> cr.cr_cap) cap_refs in
    args, cap_refs

  (* Call a random cap, passing random arguments. *)
  let do_call state () =
    match DynArray.pick state.caps with
    | None -> ()
    | Some cap_ref ->
      let cap = cap_ref.cr_cap in
      let counters = cap_ref.cr_counters in
      let target = cap_ref.cr_target in
      let n_args = Choose.int 3 in
      let args, arg_refs = n_caps state (n_args) in
      let arg_ids = List.map (fun cr -> cr.cr_target) arg_refs |> RO_array.of_list in
      RO_array.iter Core_types.inc_ref args;
      let answer = Direct.make_struct () in
      Logs.info (fun f -> f ~tags:(tags state) "Call %a=%t(%a) (answer %a)"
                    Direct.pp target cap#pp
                    (RO_array.pp Core_types.pp) args
                    Direct.pp_struct answer);
      let msg = { Msg.Request.target; counters; seq = counters.next_to_send; answer; arg_ids } in
      counters.next_to_send <- succ counters.next_to_send;
      DynArray.add state.structs (cap#call msg args, answer)

  (* Reply to a random question. *)
  let do_answer state () =
    (* Choose args before popping question, in case we run out of random data in the middle. *)
    let n_args = Choose.int 3 in
    let args, arg_refs = n_caps state (n_args) in
    match DynArray.pop state.answers_needed with
    | None -> ()
    | Some (answer, answer_id) ->
      let arg_ids = List.map (fun cr -> cr.cr_target) arg_refs in
      RO_array.iter Core_types.inc_ref args;
      Logs.info (fun f -> f ~tags:(tags state)
                    "Return %a (%a)" (RO_array.pp Core_types.pp) args Direct.pp_struct answer_id);
      Direct.return answer_id (RO_array.of_list arg_ids);
      answer#resolve (Ok ("reply", args))
      (* TODO: reply with another promise or with an error *)

  let test_service ~target:self_id vat =
    object (_ : Core_types.cap)
      inherit Core_types.service as super

      val id = Capnp_rpc.Debug.OID.next ()

      method! pp f = Fmt.pf f "test-service(%a, %t) %a"
          Capnp_rpc.Debug.OID.pp id
          super#pp_refcount
          Direct.pp self_id

      method call msg caps =
        super#check_refcount;
        let {Msg.Request.target; counters; seq; arg_ids; answer} = msg in
        if not (Direct.equal target self_id) then
          failf "Call received by %a, but expected target was %a (answer %a)"
            Direct.pp self_id
            Direct.pp target
            Direct.pp_struct answer;
        if seq <> counters.next_expected then
          failf "Expecting message number %d, but got %d (target %a)" counters.next_expected seq Direct.pp target;
        counters.next_expected <- succ counters.next_expected;
        caps |> RO_array.iteri (fun i c ->
            let target = RO_array.get arg_ids i in
            DynArray.add vat.caps (make_cap_ref ~target c)
          );
        let answer_promise = Local_struct_promise.make () in
        DynArray.add vat.answers_needed (answer_promise, answer);
        (answer_promise :> Core_types.struct_ref)
    end

  (* Pick a random cap from an answer. *)
  let do_struct state () =
    match DynArray.pick state.structs with
    | None -> ()
    | Some (s, s_id) ->
      let i = Choose.int 3 in
      Logs.info (fun f -> f ~tags:(tags state) "Get %t/%d" s#pp i);
      let cap = s#cap i in
      let target = Direct.cap s_id i in
      DynArray.add state.caps (make_cap_ref ~target cap)

  (* Finish an answer *)
  let do_finish state () =
    match DynArray.pop state.structs with
    | None -> ()
    | Some (s, _id) ->
      Logs.info (fun f -> f ~tags:(tags state) "Finish %t" s#pp);
      s#finish

  let do_release state () =
    match DynArray.pop state.caps with
    | None -> ()
    | Some cr ->
      let c = cr.cr_cap in
      Logs.info (fun f -> f ~tags:(tags state) "Release %t (%a)" c#pp Direct.pp cr.cr_target);
      Core_types.dec_ref c

  (* Create a new local service *)
  let do_create state () =
    let target = Direct.make_cap () in
    let ts = test_service ~target state in
    Logs.info (fun f -> f ~tags:(tags state) "Created %t" ts#pp);
    DynArray.add state.caps (make_cap_ref ~target ts)

  let add_actions v conn ~target =
    DynArray.add v.actions (fun () ->
        Logs.info (fun f -> f ~tags:(tags v) "Expecting bootstrap reply to be target %a" Direct.pp target);
        DynArray.add v.caps (make_cap_ref ~target @@ Endpoint.bootstrap conn)
      );
    DynArray.add v.actions (fun () ->
        Endpoint.maybe_handle_msg conn
      )

  let free_all t =
    let rec free_caps () =
      match DynArray.pop_first t.caps with
      | Some c -> Core_types.dec_ref c.cr_cap; free_caps ()
      | None -> ()
    in
    let rec free_srs () =
      match DynArray.pop_first t.structs with
      | Some (q, _) -> q#finish; free_srs ()
      | None -> ()
    in
    let rec free_ans () =
      match DynArray.pop_first t.answers_needed with
      | Some (a, _) -> a#resolve (Error (Capnp_rpc.Error.exn "Free all")); free_ans ()
      | None -> ()
    in
    free_caps ();
    free_srs ();
    free_ans ()

  let next_id = ref 0

  let create () =
    let id = !next_id in
    next_id := succ !next_id;
    let null = make_cap_ref ~target:Direct.null Core_types.null in
    let t = {
      id;
      bootstrap = None;
      caps = DynArray.create null;
      structs = DynArray.create (Core_types.broken_struct `Cancelled, Direct.cancelled);
      actions = DynArray.create ignore;
      connections = [];
      answers_needed = DynArray.create (dummy_answer, Direct.cancelled);
    } in
    let bs_id = Direct.make_cap () in
    t.bootstrap <- Some (test_service ~target:bs_id t, bs_id);
    DynArray.add t.actions (do_call t);
    DynArray.add t.actions (do_struct t);
    DynArray.add t.actions (do_finish t);
    DynArray.add t.actions (do_create t);
    DynArray.add t.actions (do_release t);
    DynArray.add t.actions (do_answer t);
    t

  let try_step t =
    List.fold_left (fun found (_, c) ->
        Endpoint.try_step c || found
      ) false t.connections

  let destroy t =
    begin match t.bootstrap with
    | None -> ()
    | Some (bs, _) -> Core_types.dec_ref bs; t.bootstrap <- None
    end;
    List.iter (fun (_, e) -> Endpoint.disconnect e) t.connections;
    t.connections <- []
end

let make_connection v1 v2 =
  let q1 = Queue.create () in
  let q2 = Queue.create () in
  let bootstrap x =
    match x.Vat.bootstrap with
    | None -> None
    | Some (c, _) -> Some c
  in
  let target = function
    | None -> Direct.null
    | Some (_, id) -> id
  in
  let v1_tags = Vat.tags v1 |> Logs.Tag.add Test_utils.peer_tag (actor_for_id v2.Vat.id) in
  let v2_tags = Vat.tags v2 |> Logs.Tag.add Test_utils.peer_tag (actor_for_id v1.Vat.id) in
  let c = Endpoint.create ~tags:v1_tags q1 q2 ?bootstrap:(bootstrap v1) in
  let s = Endpoint.create ~tags:v2_tags q2 q1 ?bootstrap:(bootstrap v2) in
  let open Vat in
  add_actions v1 c ~target:(target v2.bootstrap);
  add_actions v2 s ~target:(target v1.bootstrap);
  v1.connections <- (v2.id, c) :: v1.connections;
  v2.connections <- (v1.id, s) :: v2.connections

let run_test () =
  let v1 = Vat.create () in
  let v2 = Vat.create () in

  make_connection v1 v2;

  let vats =
    if three_vats then (
      let v3 = Vat.create () in
      make_connection v1 v3;
      [| v1; v2; v3 |]
    ) else (
      [| v1; v2 |]
    )
  in

  let free_all () =
    Logs.info (fun f -> f "Freeing everything (for debugging)");
    let rec flush () =
      let progress = Array.fold_left (fun found v ->
          Vat.try_step v || found
        ) false vats
      in
      Array.iter Vat.check vats;
      if progress then flush ()
    in
    flush ();   (* Deliver any pending calls - may add caps *)
    vats |> Array.iter (fun v ->
        Vat.free_all v;
      );
    flush ();
    vats |> Array.iter (fun v ->
        Logs.info (fun f -> f ~tags:(Vat.tags v) "{{{%a}}}" Vat.pp v);
      );
    if stop_after >= 0 then failwith "Everything freed!"
  in

  let step = ref 0 in
  try
    let rec loop () =
      let v = Choose.array vats in
      if dump_state_at_each_step then
        Logs.info (fun f -> f ~tags:(Vat.tags v) "Pre: {{{%a}}}" Vat.pp v);
      Vat.do_action v;
      if dump_state_at_each_step then
        Logs.info (fun f -> f ~tags:(Vat.tags v) "Post: {{{%a}}}}" Vat.pp v);
      if sanity_checks then (Gc.full_major (); Vat.check v);
      if !step <> stop_after then (
        incr step;
        loop ()
      ) else Logs.info (fun f -> f "Stopping early due to stop_after");
    in
    begin
      try loop ()
      with Choose.End_of_fuzz_data -> Logs.info (fun f -> f "End of fuzz data")
    end;
    free_all ();
    Array.iter Vat.destroy vats
  with ex ->
    let bt = Printexc.get_raw_backtrace () in
    Logs.err (fun f -> f "{{{%a}}}" Fmt.exn_backtrace (ex, bt));
    Logs.err (fun f -> f "Got error (at step %d) - dumping state:" !step);
    vats |> Array.iter (fun v ->
        Logs.info (fun f -> f ~tags:(Vat.tags v) "{{{%a}}}" Vat.pp v);
      );
    raise ex

let () =
  (* Logs.set_level (Some Logs.Error); *)
  AflPersistent.run @@ fun () ->
  run_test ();
  Gc.full_major ()

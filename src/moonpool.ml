module A = Atomic_

type 'a or_error = ('a, exn * Printexc.raw_backtrace) result

(** Simple blocking queue *)
module S_queue : sig
  type 'a t

  val create : unit -> _ t
  val push : 'a t -> 'a -> unit
  val pop : 'a t -> 'a
end = struct
  type 'a t = {
    mutex: Mutex.t;
    cond: Condition.t;
    q: 'a Queue.t;
  }

  let create () : _ t =
    { mutex = Mutex.create (); cond = Condition.create (); q = Queue.create () }

  let push (self : _ t) x : unit =
    Mutex.lock self.mutex;
    Queue.push x self.q;
    Condition.signal self.cond;
    Mutex.unlock self.mutex

  let pop (self : 'a t) : 'a =
    Mutex.lock self.mutex;
    let rec loop () =
      if Queue.is_empty self.q then (
        Condition.wait self.cond self.mutex;
        (loop [@tailcall]) ()
      ) else (
        let x = Queue.pop self.q in
        Mutex.unlock self.mutex;
        x
      )
    in
    loop ()
end

(** Static pool of domains *)
module D_pool_ = struct
  type domain = Domain_.t

  let work_ _i q : unit =
    while true do
      let f = S_queue.pop q in
      try f () with _ -> ()
    done

  (* A domain level worker. It should not do too much except for starting
      new threads for pools. *)
  type worker = { q: (unit -> unit) S_queue.t } [@@unboxed]

  let domains_ : worker array lazy_t =
    lazy
      (let n = Domain_.recommended_number () in
       Array.init n (fun i ->
           let q = S_queue.create () in
           let _domain : domain = Domain_.spawn (fun () -> work_ i q) in
           { q }))

  (** Number of domains in the pool *)
  let[@inline] n_domains () : int = Array.length (Lazy.force domains_)

  let run_on (i : int) (f : unit -> unit) : unit =
    let (lazy arr) = domains_ in
    assert (i < Array.length arr);
    S_queue.push arr.(i).q f
end

module Pool = struct
  (* TODO: use a better queue for the tasks *)

  type t = {
    active: bool A.t;
    threads: Thread.t array;
    q: (unit -> unit) S_queue.t;
  }

  let[@inline] run self f : unit = S_queue.push self.q f

  let worker_thread_ ~on_exn (active : bool A.t) (q : _ S_queue.t) : unit =
    while A.get active do
      let task = S_queue.pop q in
      try task ()
      with e ->
        let bt = Printexc.get_raw_backtrace () in
        on_exn e bt
    done

  let default_thread_init_exit_ ~dom_id:_ ~t_id:_ () = ()

  let create ?(on_init_thread = default_thread_init_exit_)
      ?(on_exit_thread = default_thread_init_exit_) ?(on_exn = fun _ _ -> ())
      ?(min = 1) ?(per_domain = 0) () : t =
    (* number of threads to run *)
    let min = max 1 min in
    let n_domains = D_pool_.n_domains () in
    assert (n_domains >= 1);
    let n = max min (n_domains * per_domain) in

    (* make sure we don't bias towards the first domain(s) in {!D_pool_} *)
    let offset = Random.int n_domains in

    let active = A.make true in
    let q = S_queue.create () in

    let receive_threads = S_queue.create () in

    (* start the thread with index [i] *)
    let start_thread_with_idx i =
      let dom_idx = (offset + i) mod n_domains in

      let create () =
        let thread =
          Thread.create
            (fun () ->
              let t_id = Thread.id @@ Thread.self () in
              on_init_thread ~dom_id:dom_idx ~t_id ();
              worker_thread_ ~on_exn active q;
              on_exit_thread ~dom_id:dom_idx ~t_id ())
            ()
        in
        (* send the thread from the domain back to us *)
        S_queue.push receive_threads (i, thread)
      in

      D_pool_.run_on dom_idx create
    in

    (* start all threads, placing them on the domains
       according to their index and [offset] in a round-robin fashion. *)
    let threads =
      let dummy = Thread.self () in
      Array.init n (fun i ->
          start_thread_with_idx i;
          dummy)
    in

    (* receive the newly created threads back from domains *)
    for _j = 1 to n do
      let i, th = S_queue.pop receive_threads in
      threads.(i) <- th
    done;

    { active; threads; q }

  let shutdown (self : t) : unit =
    let was_active = A.exchange self.active false in
    (* make sure to wakeup all the sleeping threads by scheduling one task each.
       This way, a thread that is asleep, waiting for tasks,
       will wakeup to process this trivial task, check [self.active], and terminate. *)
    if was_active then Array.iter (fun _ -> run self ignore) self.threads;
    Array.iter Thread.join self.threads
end

module Fut = struct
  type 'a waiter = 'a or_error -> unit

  type 'a state =
    | Done of 'a or_error
    | Waiting of 'a waiter list

  type 'a t = { st: 'a state A.t } [@@unboxed]
  type 'a promise = 'a t

  let make () =
    let fut = { st = A.make (Waiting []) } in
    fut, fut

  let of_result x : _ t = { st = A.make (Done x) }
  let[@inline] return x : _ t = of_result (Ok x)
  let[@inline] fail e bt : _ t = of_result (Error (e, bt))

  let[@inline] is_resolved self : bool =
    match A.get self.st with
    | Done _ -> true
    | Waiting _ -> false

  let[@inline] peek self : _ option =
    match A.get self.st with
    | Done x -> Some x
    | Waiting _ -> None

  let on_result (self : _ t) (f : _ waiter) : unit =
    while
      let st = A.get self.st in
      match st with
      | Done x ->
        f x;
        false
      | Waiting l ->
        let must_retry =
          not (A.compare_and_set self.st st (Waiting (f :: l)))
        in
        must_retry
    do
      ()
    done

  exception Already_fulfilled

  let fulfill (self : _ t) (r : _ result) : unit =
    while
      let st = A.get self.st in
      match st with
      | Done _ -> raise Already_fulfilled
      | Waiting l ->
        let did_swap = A.compare_and_set self.st st (Done r) in
        if did_swap then (
          (* success, now call all the waiters *)
          List.iter (fun f -> try f r with _ -> ()) l;
          false
        ) else
          true
    do
      ()
    done

  (* ### combinators ### *)

  let spawn ~on f : _ t =
    let fut, promise = make () in

    let task () =
      let res =
        try Ok (f ())
        with e ->
          let bt = Printexc.get_raw_backtrace () in
          Error (e, bt)
      in
      fulfill promise res
    in

    Pool.run on task;
    fut

  let map ?on ~f fut : _ t =
    let map_res r =
      match r with
      | Ok x ->
        (try Ok (f x)
         with e ->
           let bt = Printexc.get_raw_backtrace () in
           Error (e, bt))
      | Error e_bt -> Error e_bt
    in

    match peek fut with
    | Some r -> of_result (map_res r)
    | None ->
      let fut2, promise = make () in
      on_result fut (fun r ->
          let map_and_fulfill () =
            let res = map_res r in
            fulfill promise res
          in

          match on with
          | None -> map_and_fulfill ()
          | Some on -> Pool.run on map_and_fulfill);

      fut2

  let bind ?on ~f fut : _ t =
    let apply_f_to_res r : _ t =
      match r with
      | Ok x ->
        (try f x
         with e ->
           let bt = Printexc.get_raw_backtrace () in
           fail e bt)
      | Error (e, bt) -> fail e bt
    in

    match peek fut with
    | Some r -> apply_f_to_res r
    | None ->
      let fut2, promise = make () in
      on_result fut (fun r ->
          let bind_and_fulfill () =
            let f_res_fut = apply_f_to_res r in
            (* forward result *)
            on_result f_res_fut (fun r -> fulfill promise r)
          in

          match on with
          | None -> bind_and_fulfill ()
          | Some on -> Pool.run on bind_and_fulfill);

      fut2

  let peek_ok_assert_ (self : 'a t) : 'a =
    match A.get self.st with
    | Done (Ok x) -> x
    | _ -> assert false

  let join_container_ ~iter ~map ~len cont : _ t =
    let fut, promise = make () in
    let missing = A.make (len cont) in

    (* callback called when a future in [a] is resolved *)
    let on_res = function
      | Ok _ ->
        let n = A.fetch_and_add missing (-1) in
        if n = 1 then (
          (* last future, we know they all succeeded, so resolve [fut] *)
          let res = map peek_ok_assert_ cont in
          fulfill promise (Ok res)
        )
      | Error e_bt ->
        (* immediately cancel all other [on_res] *)
        let n = A.exchange missing 0 in
        if n > 0 then
          (* we're the only one to set to 0, so we can fulfill [fut]
             with an error. *)
          fulfill promise (Error e_bt)
    in

    iter (fun fut -> on_result fut on_res) cont;
    fut

  let join_array (a : _ t array) : _ array t =
    match Array.length a with
    | 0 -> return [||]
    | 1 -> map ?on:None a.(1) ~f:(fun x -> [| x |])
    | _ -> join_container_ ~len:Array.length ~map:Array.map ~iter:Array.iter a

  let join_list (l : _ t list) : _ list t =
    match l with
    | [] -> return []
    | [ x ] -> map ?on:None x ~f:(fun x -> [ x ])
    | _ -> join_container_ ~len:List.length ~map:List.map ~iter:List.iter l

  let for_ ~on n f : unit t =
    let futs = Array.init n (fun i -> spawn ~on (fun () -> f i)) in
    join_container_
      ~len:(fun () -> n)
      ~iter:(fun f () -> Array.iter f futs)
      ~map:(fun _f () -> ())
      ()

  (* ### blocking ### *)

  let wait_block (self : 'a t) : 'a or_error =
    match peek self with
    | Some x ->
      (* fast path *)
      x
    | None ->
      (* use queue only once *)
      let q = S_queue.create () in
      on_result self (fun r -> S_queue.push q r);
      S_queue.pop q

  let wait_block_exn self =
    match wait_block self with
    | Ok x -> x
    | Error (e, bt) -> Printexc.raise_with_backtrace e bt
end

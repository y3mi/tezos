(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2017.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Logging.Node.State

type error +=
  | Unknown_network of Net_id.t

type error += Bad_data_dir

let () =
  Error_monad.register_error_kind
    `Temporary
    ~id:"state.unknown_network"
    ~title:"Unknown network"
    ~description:"TODO"
    ~pp:(fun ppf id ->
        Format.fprintf ppf "Unknown network %a" Net_id.pp id)
    Data_encoding.(obj1 (req "net" Net_id.encoding))
    (function Unknown_network x -> Some x | _ -> None)
    (fun x -> Unknown_network x) ;
  Error_monad.register_error_kind
    `Permanent
    ~id:"badDataDir"
    ~title:"Bad data directory"
    ~description:"The data directory could not be read. \
                  This could be because it was generated with an \
                  old version of the tezos-node program. \
                  Deleting and regenerating this directory \
                  may fix the problem."
    Data_encoding.empty
    (function Bad_data_dir -> Some () | _ -> None)
    (fun () -> Bad_data_dir) ;

  (** *)

module Shared = struct
  type 'a t = {
    data: 'a ;
    lock: Lwt_mutex.t ;
  }
  let create data = { data ; lock = Lwt_mutex.create () }
  let use { data ; lock } f =
    Lwt_mutex.with_lock lock (fun () -> f data)
end

type global_state = {
  global_data: global_data Shared.t ;
  protocol_store: Store.Protocol.store Shared.t ;
}

and global_data = {
  nets: net_state Net_id.Table.t ;
  global_store: Store.t ;
  context_index: Context.index ;
}

and net_state = {
  global_state: global_state ;
  net_id: Net_id.t ;
  genesis: genesis ;
  faked_genesis_hash: Block_hash.t ;
  expiration: Time.t option ;
  allow_forked_network: bool ;
  block_store: Store.Block.store Shared.t ;
  context_index: Context.index Shared.t ;
  block_watcher: block Watcher.input ;
  chain_state: chain_state Shared.t ;
}

and genesis = {
  time: Time.t ;
  block: Block_hash.t ;
  protocol: Protocol_hash.t ;
}

and chain_state = {
  mutable data: chain_data ;
  chain_store: Store.Chain.store ;
}

and chain_data = {
  current_head: block ;
  current_reversed_mempool: Operation_hash.t list ;
}

and block = {
  net_state: net_state ;
  hash: Block_hash.t ;
  contents: Store.Block.contents ;
}

let read_chain_store { chain_state } f =
  Shared.use chain_state begin fun state ->
    f state.chain_store state.data
  end

let update_chain_store { net_id ; context_index ; chain_state } f =
  Shared.use chain_state begin fun state ->
    f state.chain_store state.data >>= fun (data, res) ->
    Lwt_utils.may data
      ~f:begin fun data ->
        state.data <- data ;
        Shared.use context_index begin fun context_index ->
          Context.set_head context_index net_id
            data.current_head.contents.context
        end >>= fun () ->
        Lwt.return_unit
      end >>= fun () ->
    Lwt.return res
  end

type t = global_state

module Locked_block = struct

  let store_genesis store genesis commit =
    let net_id = Net_id.of_block_hash genesis.block in
    let shell : Block_header.shell_header = {
      net_id ;
      level = 0l ;
      proto_level = 0 ;
      predecessor = genesis.block ;
      timestamp = genesis.time ;
      fitness = [] ;
      validation_passes = 0 ;
      operations_hash = Operation_list_list_hash.empty ;
    } in
    let header : Block_header.t = { shell ; proto = MBytes.create 0 } in
    Store.Block.Contents.store (store, genesis.block)
      { Store.Block.header ; message = "Genesis" ;
        max_operations_ttl = 0 ; context = commit } >>= fun () ->
    Lwt.return header

end

module Net = struct

  type nonrec genesis = genesis = {
    time: Time.t ;
    block: Block_hash.t ;
    protocol: Protocol_hash.t ;
  }
  let genesis_encoding =
    let open Data_encoding in
    conv
      (fun { time ; block ; protocol } -> (time, block, protocol))
      (fun (time, block, protocol) -> { time ; block ; protocol })
      (obj3
         (req "timestamp" Time.encoding)
         (req "block" Block_hash.encoding)
         (req "protocol" Protocol_hash.encoding))

  type t = net_state
  type net_state = t

  let allocate
      ~genesis ~faked_genesis_hash ~expiration ~allow_forked_network
      ~current_head
      global_state context_index chain_store block_store =
    Store.Block.Contents.read_exn
      (block_store, current_head) >>= fun current_block ->
    let rec chain_state = {
      data = {
        current_head = {
          net_state ;
          hash = current_head ;
          contents = current_block ;
        } ;
        current_reversed_mempool = [] ;
      } ;
      chain_store ;
    }
    and net_state = {
      global_state ;
      net_id = Net_id.of_block_hash genesis.block ;
      chain_state = { Shared.data = chain_state ; lock = Lwt_mutex.create () } ;
      genesis ; faked_genesis_hash ;
      expiration ;
      allow_forked_network ;
      block_store = Shared.create block_store ;
      context_index = Shared.create context_index ;
      block_watcher = Watcher.create_input () ;
    } in
    Lwt.return net_state

  let locked_create
      global_state data ?expiration ?(allow_forked_network = false)
      net_id genesis commit =
    let net_store = Store.Net.get data.global_store net_id in
    let block_store = Store.Block.get net_store
    and chain_store = Store.Chain.get net_store in
    Store.Net.Genesis_hash.store net_store genesis.block >>= fun () ->
    Store.Net.Genesis_time.store net_store genesis.time >>= fun () ->
    Store.Net.Genesis_protocol.store net_store genesis.protocol >>= fun () ->
    Store.Chain.Current_head.store chain_store genesis.block >>= fun () ->
    Store.Chain.Known_heads.store chain_store genesis.block >>= fun () ->
    begin
      match expiration with
      | None -> Lwt.return_unit
      | Some time -> Store.Net.Expiration.store net_store time
    end >>= fun () ->
    begin
      if allow_forked_network then
        Store.Net.Allow_forked_network.store data.global_store net_id
      else
        Lwt.return_unit
    end >>= fun () ->
    Locked_block.store_genesis
      block_store genesis commit >>= fun genesis_header ->
    allocate
      ~genesis
      ~faked_genesis_hash:(Block_header.hash genesis_header)
      ~current_head:genesis.block
      ~expiration
      ~allow_forked_network
      global_state
      data.context_index
      chain_store
      block_store

  let create state ?allow_forked_network genesis  =
    let net_id = Net_id.of_block_hash genesis.block in
    Shared.use state.global_data begin fun data ->
      if Net_id.Table.mem data.nets net_id then
        Pervasives.failwith "State.Net.create"
      else
        Context.commit_genesis
          data.context_index
          ~net_id
          ~time:genesis.time
          ~protocol:genesis.protocol >>= fun commit ->
        locked_create
          state data ?allow_forked_network net_id genesis commit >>= fun net ->
        Net_id.Table.add data.nets net_id net ;
        Lwt.return net
    end

  let locked_read global_state data id =
    let net_store = Store.Net.get data.global_store id in
    let block_store = Store.Block.get net_store
    and chain_store = Store.Chain.get net_store in
    Store.Net.Genesis_hash.read net_store >>=? fun genesis_hash ->
    Store.Net.Genesis_time.read net_store >>=? fun time ->
    Store.Net.Genesis_protocol.read net_store >>=? fun protocol ->
    Store.Net.Expiration.read_opt net_store >>= fun expiration ->
    Store.Net.Allow_forked_network.known
      data.global_store id >>= fun allow_forked_network ->
    Store.Block.Contents.read (block_store, genesis_hash) >>=? fun genesis_header ->
    let genesis = { time ; protocol ; block = genesis_hash } in
    Store.Chain.Current_head.read chain_store >>=? fun current_head ->
    try
      allocate
        ~genesis
        ~faked_genesis_hash:(Block_header.hash genesis_header.header)
        ~current_head
        ~expiration
        ~allow_forked_network
        global_state
        data.context_index
        chain_store
        block_store >>= return
    with Not_found ->
      fail Bad_data_dir

  let locked_read_all global_state data =
    Store.Net.list data.global_store >>= fun ids ->
    iter_p
      (fun id ->
         locked_read global_state data id >>=? fun net ->
         Net_id.Table.add data.nets id net ;
         return ())
      ids

  let read_all state =
    Shared.use state.global_data begin fun data ->
      locked_read_all state data
    end

  let get state id =
    Shared.use state.global_data begin fun data ->
      try return (Net_id.Table.find data.nets id)
      with Not_found -> fail (Unknown_network id)
    end

  let all state =
    Shared.use state.global_data begin fun { nets } ->
      Lwt.return @@
      Net_id.Table.fold (fun _ net acc -> net :: acc) nets []
    end

  let id { net_id } = net_id
  let genesis { genesis } = genesis
  let faked_genesis_hash { faked_genesis_hash } = faked_genesis_hash
  let expiration { expiration } = expiration
  let allow_forked_network { allow_forked_network } = allow_forked_network
  let global_state { global_state } = global_state

  let destroy state net =
    lwt_debug "destroy %a" Net_id.pp (id net) >>= fun () ->
    Shared.use state.global_data begin fun { global_store ; nets } ->
      Net_id.Table.remove nets (id net) ;
      Store.Net.destroy global_store (id net) >>= fun () ->
      Lwt.return_unit
    end

end

module Block = struct

  type t = block = {
    net_state: Net.t ;
    hash: Block_hash.t ;
    contents: Store.Block.contents ;
  }
  type block = t

  let compare b1 b2 = Block_hash.compare b1.hash b2.hash
  let equal b1 b2 = Block_hash.equal b1.hash b2.hash

  let hash { hash } = hash
  let header { contents = { header } } = header
  let net_state { net_state } = net_state
  let shell_header { contents = { header = { shell } } } = shell
  let net_id b = (shell_header b).net_id
  let timestamp b = (shell_header b).timestamp
  let fitness b = (shell_header b).fitness
  let level b = (shell_header b).level
  let proto_level b = (shell_header b).proto_level
  let validation_passes b = (shell_header b).validation_passes
  let message { contents = { message } } = message
  let max_operations_ttl { contents = { max_operations_ttl } } =
    max_operations_ttl

  let known_valid net_state hash =
    Shared.use net_state.block_store begin fun store ->
      Store.Block.Contents.known (store, hash)
    end
  let known_invalid net_state hash =
    Shared.use net_state.block_store begin fun store ->
      Store.Block.Invalid_block.known store hash
    end

  let known net_state hash =
    Shared.use net_state.block_store begin fun store ->
      Store.Block.Contents.known (store, hash) >>= fun known ->
      if known then
        Lwt.return_true
      else
        Store.Block.Invalid_block.known store hash
    end

  let read net_state hash =
    Shared.use net_state.block_store begin fun store ->
      Store.Block.Contents.read (store, hash) >>=? fun contents ->
      return { net_state ; hash ; contents }
    end
  let read_opt net_state hash =
    read net_state hash >>= function
    | Error _ -> Lwt.return None
    | Ok v -> Lwt.return (Some v)
  let read_exn net_state hash =
    Shared.use net_state.block_store begin fun store ->
      Store.Block.Contents.read_exn (store, hash) >>= fun contents ->
      Lwt.return { net_state ; hash ; contents }
    end

  (* Quick accessor to be optimized ?? *)
  let read_predecessor net_state hash =
    read net_state hash >>=? fun { contents = { header } } ->
    return header.shell.predecessor
  let read_predecessor_opt net_state hash =
    read_predecessor net_state hash >>= function
    | Error _ -> Lwt.return None
    | Ok v -> Lwt.return (Some v)
  let read_predecessor_exn net_state hash =
    read_exn net_state hash >>= fun { contents = { header } } ->
    Lwt.return header.shell.predecessor

  let predecessor { net_state ; contents = { header } ; hash } =
    if Block_hash.equal hash header.shell.predecessor then
      Lwt.return_none
    else
      read_exn net_state header.shell.predecessor >>= fun block ->
      Lwt.return (Some block)

  let store
      net_state block_header operations
      { Updater.context ; fitness ; message ; max_operations_ttl } =
    let bytes = Block_header.to_bytes block_header in
    let hash = Block_header.hash_raw bytes in
    (* let's the validator check the consistency... of fitness, level, ... *)
    let message =
      match message with
      | Some message -> message
      | None ->
          Format.asprintf "%a(%ld): %a"
            Block_hash.pp_short hash
            block_header.shell.level
            Fitness.pp fitness in
    Shared.use net_state.block_store begin fun store ->
      Store.Block.Invalid_block.known store hash >>= fun known_invalid ->
      fail_when known_invalid (failure "Known invalid") >>=? fun () ->
      Store.Block.Contents.known (store, hash) >>= fun known ->
      if known then
        return None
      else begin
        Context.commit
          ~time:block_header.shell.timestamp ~message context >>= fun commit ->
        let contents = {
          Store.Block.header = block_header ;
          message ;
          max_operations_ttl ;
          context = commit ;
        } in
        Store.Block.Contents.store (store, hash) contents >>= fun () ->
        let hashes = List.map (List.map Operation.hash) operations in
        let list_hashes = List.map Operation_list_hash.compute hashes in
        Lwt_list.iteri_p
          (fun i hashes ->
             let path = Operation_list_list_hash.compute_path list_hashes i in
             Store.Block.Operation_hashes.store
               (store, hash) i hashes >>= fun () ->
             Store.Block.Operation_path.store (store, hash) i path)
          hashes >>= fun () ->
        Lwt_list.iteri_p
          (fun i ops -> Store.Block.Operations.store (store, hash) i ops)
          operations >>= fun () ->
        (* Update the chain state. *)
        Shared.use net_state.chain_state begin fun chain_state ->
          let store = chain_state.chain_store in
          let predecessor = block_header.shell.predecessor in
          Store.Chain.Known_heads.remove store predecessor >>= fun () ->
          Store.Chain.Known_heads.store store hash
        end >>= fun () ->
        let block = { net_state ; hash ; contents } in
        Watcher.notify net_state.block_watcher block ;
        return (Some block)
      end
    end

  let store_invalid net_state block_header =
    let bytes = Block_header.to_bytes block_header in
    let hash = Block_header.hash_raw bytes in
    Shared.use net_state.block_store begin fun store ->
      Store.Block.Contents.known (store, hash) >>= fun known_valid ->
      fail_when known_valid (failure "Known valid") >>=? fun () ->
      Store.Block.Invalid_block.known store hash >>= fun known_invalid ->
      if known_invalid then
        return false
      else
        Store.Block.Invalid_block.store store hash
          { level = block_header.shell.level } >>= fun () ->
        return true
    end

  let watcher net_state =
    Watcher.create_stream net_state.block_watcher

  let operation_hashes { net_state ; hash ; contents } i =
    if i < 0 || contents.header.shell.validation_passes <= i then
      invalid_arg "State.Block.operations" ;
    Shared.use net_state.block_store begin fun store ->
      Store.Block.Operation_hashes.read_exn (store, hash) i >>= fun hashes ->
      Store.Block.Operation_path.read_exn (store, hash) i >>= fun path ->
      Lwt.return (hashes, path)
    end

  let all_operation_hashes { net_state ; hash ; contents } =
    Shared.use net_state.block_store begin fun store ->
      Lwt_list.map_p
        (Store.Block.Operation_hashes.read_exn (store, hash))
        (0 -- (contents.header.shell.validation_passes - 1))
    end

  let operations { net_state ; hash ; contents } i =
    if i < 0 || contents.header.shell.validation_passes <= i then
      invalid_arg "State.Block.operations" ;
    Shared.use net_state.block_store begin fun store ->
      Store.Block.Operation_path.read_exn (store, hash) i >>= fun path ->
      Store.Block.Operations.read_exn (store, hash) i >>= fun ops ->
      Lwt.return (ops, path)
    end

  let all_operations { net_state ; hash ; contents } =
    Shared.use net_state.block_store begin fun store ->
      Lwt_list.map_p
        (fun i -> Store.Block.Operations.read_exn (store, hash) i)
        (0 -- (contents.header.shell.validation_passes - 1))
    end

  let context { net_state ; hash } =
    Shared.use net_state.block_store begin fun block_store ->
      Store.Block.Contents.read_exn (block_store, hash)
    end  >>= fun { context = commit } ->
    Shared.use net_state.context_index begin fun context_index ->
      Context.checkout_exn context_index commit
    end

  let protocol_hash block =
    context block >>= fun context ->
    Context.get_protocol context

  let test_network block =
    context block >>= fun context ->
    Context.get_test_network context

end

let read_block { global_data } hash =
  Shared.use global_data begin fun { nets } ->
    Net_id.Table.fold
      (fun _net_id net_state acc ->
         acc >>= function
         | Some _ -> acc
         | None ->
             Block.read_opt net_state hash >>= function
             | None -> acc
             | Some block -> Lwt.return (Some block))
      nets
      Lwt.return_none
  end

let read_block_exn t hash =
  read_block t hash >>= function
  | None -> Lwt.fail Not_found
  | Some b -> Lwt.return b

let fork_testnet block protocol expiration =
  Shared.use block.net_state.global_state.global_data begin fun data ->
    Block.context block >>= fun context ->
    Context.set_test_network context Not_running >>= fun context ->
    Context.set_protocol context protocol >>= fun context ->
    Context.commit_test_network_genesis
      data.context_index block.hash block.contents.header.shell.timestamp
      context >>=? fun (net_id, genesis, commit) ->
    let genesis = {
      block = genesis ;
      time = Time.add block.contents.header.shell.timestamp 1L ;
      protocol ;
    } in
    Net.locked_create block.net_state.global_state data
      net_id ~expiration genesis commit >>= fun net ->
    return net
  end

module Protocol = struct

  let known global_state hash =
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.Contents.known store hash
    end

  let read global_state hash =
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.Contents.read store hash
    end
  let read_opt global_state hash =
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.Contents.read_opt store hash
    end
  let read_exn global_state hash =
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.Contents.read_exn store hash
    end

  let read_raw global_state hash =
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.RawContents.read (store, hash)
    end
  let read_raw_opt global_state hash =
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.RawContents.read_opt (store, hash)
    end
  let read_raw_exn global_state hash =
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.RawContents.read_exn (store, hash)
    end

  let store global_state p =
    let bytes = Protocol.to_bytes p in
    let hash = Protocol.hash_raw bytes in
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.Contents.known store hash >>= fun known ->
      if known then
        Lwt.return None
      else
        Store.Protocol.RawContents.store (store, hash) bytes >>= fun () ->
        Lwt.return (Some hash)
    end

  let remove global_state hash =
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.Contents.known store hash >>= fun known ->
      if known then
        Lwt.return_false
      else
        Store.Protocol.Contents.remove store hash >>= fun () ->
        Lwt.return_true
    end

  let list global_state =
    Shared.use global_state.protocol_store begin fun store ->
      Store.Protocol.Contents.fold_keys store
        ~init:Protocol_hash.Set.empty
        ~f:(fun x acc -> Lwt.return (Protocol_hash.Set.add x acc))
    end

end

module Registred_protocol = struct

  module type T = sig
    val hash: Protocol_hash.t
    include Updater.NODE_PROTOCOL
    val complete_b58prefix : Context.t -> string -> string list Lwt.t
  end

  type t = (module T)

  let build_v1 hash =
    let (module F) = Tezos_protocol_compiler.Registerer.get_exn hash in
    let module Name = struct
      let name = Protocol_hash.to_b58check hash
    end in
    let module Env = Tezos_protocol_environment.Make(Name)() in
    (module struct
      let hash = hash
      module P = F(Env)
      include P
      include Updater.LiftProtocol(Name)(Env)(P)
      let complete_b58prefix = Env.Context.complete
    end : T)

  module VersionTable = Protocol_hash.Table

  let versions : (module T) VersionTable.t =
    VersionTable.create 20

  let mem hash =
    VersionTable.mem versions hash ||
    Tezos_protocol_compiler.Registerer.mem hash

  let get_exn hash =
    try VersionTable.find versions hash
    with Not_found ->
      let proto = build_v1 hash in
      VersionTable.add versions hash proto ;
      proto

  let get hash =
    try Some (get_exn hash)
    with Not_found -> None

end

module Register_embedded_protocol
    (Env : Updater.Node_protocol_environment_sigs.V1)
    (Proto : Env.Updater.PROTOCOL)
    (Source : sig
       val hash: Protocol_hash.t option
       val sources: Tezos_data.Protocol.t
     end) = struct

  let () =
    let hash =
      match Source.hash with
      | None -> Tezos_data.Protocol.hash Source.sources
      | Some hash -> hash in
    let module Name = struct
      let name = Protocol_hash.to_b58check hash
    end in
    (* TODO add a memory table for "embedded" sources... *)
    Registred_protocol.VersionTable.add
      Registred_protocol.versions hash
      (module struct
        let hash = hash
        include Proto
        include Updater.LiftProtocol(Name)(Env)(Proto)
        let complete_b58prefix = Env.Context.complete
      end : Registred_protocol.T)

end

let read
    ?patch_context
    ~store_root
    ~context_root
    () =
  Store.init store_root >>=? fun global_store ->
  Context.init ?patch_context ~root:context_root >>= fun context_index ->
  let global_data = {
    nets = Net_id.Table.create 17 ;
    global_store ;
    context_index ;
  } in
  let state = {
    global_data = Shared.create global_data ;
    protocol_store = Shared.create @@ Store.Protocol.get global_store ;
  } in
  Net.read_all state >>=? fun () ->
  return state

let close { global_data } =
  Shared.use global_data begin fun { global_store } ->
    Store.close global_store ;
    Lwt.return_unit
  end

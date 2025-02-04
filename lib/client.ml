let hard_bytes =
  let init = Bytes.make 160 (Char.chr 0xD5) in
  Bytes.set init 0 (Char.chr 0);
  init

let mock_bytes = Bytes.make 160 (Char.chr 0xD5)

let hard_cs =
  let init = Cstruct.create 160 in
  Cstruct.memset init 0xD1;
  init

let mock_cs =
  let init = Cstruct.create 160 in
  Cstruct.memset init 0xD5;
  init

let client_loop ~clock ~main_client ~interval ~create_payload ~terminate_p
    ~insert_sent_timestamp ~get_timestamps write read =
  let play_done, play_done_resolver = Eio.Promise.create () in
  let last_timestamp = Eio.Time.now clock |> ref in
  let sent_counter = ref 0 in
  let received_counter = ref 0 in
  let play () =
    Eio.Fiber.first
      (fun () -> Eio.Promise.await terminate_p)
      (fun () ->
        let rec loop proc_time =
          let loop_start = Eio.Time.now clock in
          let sleep_time = interval -. proc_time in
          Eio.Time.sleep clock sleep_time;

          let now = Eio.Time.now clock in
          if main_client then last_timestamp := now;
          let chunk = create_payload () in
          incr sent_counter;
          if main_client then
            (* Printf.printf "Sending packet number %i\n%!" !sent_counter; *)
            insert_sent_timestamp ~timestamp:now chunk;
          write chunk;
          loop (Eio.Time.now clock -. loop_start -. sleep_time)
        in
        loop 0.);
    Eio.Promise.resolve play_done_resolver None
  in
  let listen () =
    let rec loop req_seq : unit =
      match
        Eio.Fiber.first
          (fun () -> Some (req_seq ()))
          (fun () -> Eio.Promise.await play_done)
      with
      | Some (Seq.Cons (packet, next)) ->
          if main_client then (
            incr received_counter;
            let now = Eio.Time.now clock in
            let latency = now -. !last_timestamp in

            if main_client then (
              let client_sent, server_looped = get_timestamps packet in

              (* Printf.printf *)
              (*   "Received packet number %i, overall latency: %f | client to \ *)
               (*    server in %f | server to client in %f\n\ *)
               (*    %!" *)
              (*   !received_counter latency *)
              (*   (server_looped -. client_sent) *)
              (*   (now -. server_looped); *)
              Printf.printf "%i,%f,%f,%f\n%!" !received_counter latency
                (server_looped -. client_sent)
                (now -. server_looped);

              ()));

          loop next
      | _ -> ()
    in
    loop read
  in

  Eio.Fiber.both play listen

let socket_of_addr sw net addr =
  let uri = Uri.of_string addr in
  let scheme = Uri.scheme uri |> Option.value ~default:"http" in
  let host =
    match Uri.host uri with
    | None -> invalid_arg "No host in uri"
    | Some host -> host
  in
  let port =
    Uri.port uri
    |> Option.value
         ~default:
           (match scheme with
           | "http" -> 80
           | "https" -> 443
           | _ -> failwith "Don't know default port for this scheme")
  in

  let inet, port =
    Eio_unix.run_in_systhread (fun () ->
        Unix.getaddrinfo host (string_of_int port) [ Unix.(AI_FAMILY PF_INET) ])
    |> List.filter_map (fun (addr : Unix.addr_info) ->
           match addr.ai_addr with
           | Unix.ADDR_UNIX _ -> None
           | ADDR_INET (addr, port) -> Some (addr, port))
    |> List.hd
  in
  let addr = `Tcp (Eio_unix.Net.Ipaddr.of_unix inet, port) in

  (Eio.Net.connect ~sw net addr, scheme)

module H2 = struct
  let run ~terminate_p ~main_client ~interval env sw port =
    let socket, scheme =
      socket_of_addr sw env#net (Format.sprintf "http://127.0.0.1:%i" port)
    in
    let conn =
      H2_eio.Client.create_connection ~sw
        ~error_handler:(fun err ->
          match err with
          | `Exn exn -> print_endline @@ Printexc.to_string exn
          | _ -> Printf.printf "Other erra creating client connection\n%!")
        socket
    in

    let request =
      H2.Request.create ~scheme
        ~headers:
          (H2.Headers.of_list
             [ (":authority", "127.0.0.1"); ("content-type", "text/html") ])
        `POST "/"
    in

    let receive_stream = Eio.Stream.create 0 in

    let response_handler _ reader =
      Eio.Fiber.fork ~sw (fun () ->
          let resp_stream = Eio.Stream.create 0 in
          let schedule_read () =
            H2.Body.Reader.schedule_read reader
              ~on_eof:(fun () -> Printf.printf "End of file\n%!")
              ~on_read:(fun bs ~off ~len ->
                let cs = Cstruct.of_bigarray ~off ~len bs in
                Eio.Stream.add resp_stream @@ fun () ->
                Eio.Stream.add receive_stream (Some cs))
          in
          schedule_read ();

          let rec loop () : unit =
            let receive = Eio.Stream.take resp_stream in
            receive ();
            schedule_read ();
            loop ()
          in
          loop ())
    in

    let body_writer =
      H2_eio.Client.request
        ~error_handler:(fun err ->
          match err with
          | `Exn exn -> print_endline @@ Printexc.to_string exn
          | _ -> Printf.printf "Other client erra\n%!")
        ~trailers_handler:ignore ~response_handler conn request
    in

    let write (cs : Cstruct.t) =
      H2.Body.Writer.write_bigstring body_writer ~off:cs.off ~len:cs.len
        cs.buffer
    in
    let read : Cstruct.t Seq.t =
      let rec next () =
        match Eio.Stream.take receive_stream with
        | None -> Seq.Nil
        | Some cs -> Cons (cs, next)
      in
      next
    in

    let create_payload () = if main_client then hard_cs else mock_cs in

    let insert_sent_timestamp ~timestamp packet =
      Cstruct.LE.set_uint64 packet 0 (Int64.bits_of_float timestamp)
    in

    let get_timestamps packet =
      ( Cstruct.LE.get_uint64 packet 0 |> Int64.float_of_bits,
        Cstruct.LE.get_uint64 packet 8 |> Int64.float_of_bits )
    in

    Eio.Fiber.first
      (fun () ->
        client_loop ~clock:env#clock ~main_client ~interval ~terminate_p
          ~create_payload ~insert_sent_timestamp ~get_timestamps write read)
      (fun () -> Eio.Promise.await terminate_p);
    Eio.Promise.await @@ H2_eio.Client.shutdown conn
end

let run ~terminate_p ~main_client ~interval env port =
  Printf.printf "Starting client\n%!";

  Eio.Switch.run @@ fun sw ->
  let io =
    Fake_grpc_io.create_client ~net:env#net ~sw
      (Format.sprintf "http://127.0.0.1:%i" port)
  in

  H2LoadTest_client.Result.run ~sw ~io (fun _ ~writer ~read ->
      let write paylaod = writer paylaod |> ignore in
      let create_payload () =
        {
          H2_load_test_rpc.timestamp = Eio.Time.now env#clock;
          audio = (if main_client then hard_bytes else mock_bytes);
        }
      in

      let insert_sent_timestamp ~timestamp packet =
        Bytes.set_int64_le packet.H2_load_test_rpc.audio 0
          (Int64.bits_of_float timestamp)
      in

      let get_timestamps packet =
        ( Bytes.get_int64_le packet.H2_load_test_rpc.audio 0 |> Int64.float_of_bits,
          Bytes.get_int64_le packet.audio 0 |> Int64.float_of_bits )
      in

      client_loop ~clock:env#clock ~main_client ~terminate_p ~interval
        ~create_payload ~insert_sent_timestamp ~get_timestamps write read)
  |> ignore

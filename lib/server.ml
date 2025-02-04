module H2 = struct
  let run env sw port terminate_p =
    let addr = `Tcp (Eio.Net.Ipaddr.V4.any, port) in
    let server_socket =
      Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:10 addr
    in
    let conn_counter = ref 0 in
    let packet_counter = ref 0 in

    let request_handler _ reqd =
      incr conn_counter;
      Printf.printf "Handling connection %i\n%!" !conn_counter;
      let response = H2.Response.create `OK in
      let body_writer = H2.Reqd.respond_with_streaming reqd response in
      let body_reader = H2.Reqd.request_body reqd in

      let resp_stream = Eio.Stream.create 0 in
      let schedule_read () =
        H2.Body.Reader.schedule_read body_reader
          ~on_eof:(fun () -> Printf.printf "End of file\n%!")
          ~on_read:(fun bs ~off ~len ->
            let cs = Cstruct.of_bigarray ~off ~len bs in
            if Cstruct.get cs 100 = Char.chr 0xD1 then (
              incr packet_counter;
              Printf.printf "Received packet number %i\n%!" !packet_counter;

              Cstruct.LE.set_uint64 cs 8
                (Eio.Time.now env#clock |> Int64.bits_of_float));

            Eio.Stream.add resp_stream @@ fun () ->
            H2.Body.Writer.write_bigstring body_writer ~off ~len cs.buffer;
            H2.Body.Writer.flush body_writer ignore)
      in
      schedule_read ();

      let rec loop () : unit =
        let send_back = Eio.Stream.take resp_stream in
        send_back ();
        schedule_read ();
        loop ()
      in
      loop ()
    in

    let connection_handler socket client_addr =
      H2_eio.Server.create_connection_handler
        ~error_handler:(fun _ ?request:_ err _ ->
          match err with
          | `Bad_request -> Printf.printf "Bad request erra\n%!"
          | `Internal_server_error -> Printf.printf "Internal server erra\n%!"
          | `Exn exn -> print_endline @@ Printexc.to_string exn)
        ~request_handler:(fun net_resp reqd ->
          Eio.Fiber.fork ~sw (fun () -> request_handler net_resp reqd))
        ~sw client_addr socket
    in

    Printf.printf "Starting HTTP/2 server on port %i...\n%!" port;
    Eio.Net.run_server
      ~on_error:(fun exn -> Eio.traceln "%s" (Printexc.to_string exn))
      ~stop:terminate_p server_socket connection_handler
end

let serve port server env terminate_c =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.any, port) in
  Eio.Switch.run @@ fun sw ->
  let server_socket =
    Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:10 addr
  in

  let connection_handler socket client_addr =
    Eio.Switch.run (fun sw ->
        Io_server_h2_ocaml_protoc.connection_handler
          ~grpc_error_handler:(fun exn ->
            print_endline (Printexc.to_string exn);
            print_endline (Printexc.get_backtrace ());
            [])
          ~sw server socket client_addr)
  in

  Eio.Net.run_server
    ~on_error:(fun exn -> Eio.traceln "%s" (Printexc.to_string exn))
    ~stop:terminate_c server_socket connection_handler

let run env port terminate_p =
  Printf.printf "Starting server on %i\n%!" port;
  let conn_counter = ref 0 in
  let module Implementation : H2LoadTest_server.Implementation = struct
    let run _ (req_seq : H2_load_test_rpc.packet Seq.t)
        (write : H2_load_test_rpc.packet -> unit) =
      incr conn_counter;
      Printf.printf "Handling connection %i\n%!" !conn_counter;
      Seq.iter
        (fun packet ->
          if Bytes.get packet.H2_load_test_rpc.audio 0 = Char.chr 0 then
            Printf.printf "Looping back the packet\n%!";
          write packet)
        req_seq;
      []
  end in
  serve port
    (H2LoadTest_server.create_server (module Implementation))
    env terminate_p

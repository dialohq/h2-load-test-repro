let h2 = ref false

let () =
  Arg.parse
    [
      ( "--h2",
        Unit (fun () -> h2 := true),
        Printf.sprintf "Run HTTP/2 only (default: %b)" !h2 );
    ]
    (fun name -> raise (Arg.Bad ("Don't know what I should do with : " ^ name)))
    (Printf.sprintf "Usage: %s " Sys.argv.(0))

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let second_signal = ref false in
  let terminate_p, terminate_r = Eio.Promise.create () in
  let main_interval = 0.2 in
  let conn_n = 1000 in

  Sys.set_signal Sys.sigint
    (Signal_handle
       (fun _ ->
         if !second_signal then exit 0 else 
         Printf.printf "Stopping...\n%!";
         second_signal := true;
         Eio.Promise.resolve terminate_r ()));

  Printf.printf "packet_n,roundtrip,client_sent,server_sent\n%!";

  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Fiber.all
        (List.init conn_n (fun n ->
             fun () ->
              Eio.Time.sleep env#clock (float_of_int n *. 0.05);
              if !h2 then
                H2_load_test.Client.H2.run ~terminate_p ~main_client:false
                  ~interval:(0.1 -. Random.float 0.08)
                  env sw 8888
              else
                H2_load_test.Client.run ~terminate_p ~main_client:false
                  ~interval:(0.1 -. Random.float 0.08)
                  env 8888));
      `Stop_daemon);
  if !h2 then
    H2_load_test.Client.H2.run ~terminate_p ~main_client:true ~interval:main_interval
      env sw 8888
  else
    H2_load_test.Client.run ~terminate_p ~main_client:true ~interval:main_interval
      env 8888

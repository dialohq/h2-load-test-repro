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

  Sys.set_signal Sys.sigint
    (Signal_handle
       (fun _ ->
         if !second_signal then (
           Printf.printf "Forcing stop.\n%!";
           exit 0)
         else Printf.printf "Stopping...\n%!";
         second_signal := true;
         Eio.Promise.resolve terminate_r ()));

  if !h2 then H2_load_test.Server.H2.run env sw 8888 terminate_p
  else H2_load_test.Server.run env 8888 terminate_p

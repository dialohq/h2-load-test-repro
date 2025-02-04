module H2 : sig
  val run :
    terminate_p:unit Eio.Promise.t ->
    main_client:bool ->
    interval:float ->
    Eio_unix.Stdenv.base ->
    Eio.Switch.t ->
    int ->
    unit
end

val run :
  terminate_p:unit Eio.Promise.t ->
  main_client:bool ->
  interval:float ->
  Eio_unix.Stdenv.base ->
  int ->
  unit

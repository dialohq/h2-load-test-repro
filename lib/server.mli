module H2 : sig
  val run :
    Eio_unix.Stdenv.base -> Eio.Switch.t -> int -> unit Eio.Promise.t -> unit
end

val run : Eio_unix.Stdenv.base -> int -> unit Eio.Promise.t -> unit

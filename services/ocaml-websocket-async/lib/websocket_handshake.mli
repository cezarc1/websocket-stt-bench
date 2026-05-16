val accept_key : key:string -> string
val upgrade_key : Http1.request -> string option
val write_upgrade_response : Async.Writer.t -> ws_key:string -> unit Async.Deferred.t

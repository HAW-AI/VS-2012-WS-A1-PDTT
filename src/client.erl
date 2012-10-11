-module(client).
-import(werkzeug, [get_config_value/2,logging/2,timeMilliSecond/0,delete_last/1]).

-compile([export_all]).

start(ServerPID) ->
  ClientPID = spawn(fun() -> loop(redakteur, ServerPID) end),
  ClientPID.

redakteur() ->
  ok.


leser() ->
  ok.

loop(ClientType, ServerPID) ->
  ServerPID ! {foo},
  timer:sleep(5000),
  loop(ClientType, ServerPID).

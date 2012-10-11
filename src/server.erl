-module(server).
-import(werkzeug, [get_config_value/2,logging/2,timeMilliSecond/0,delete_last/1]).

-compile([export_all]).

start() ->
  {ok, Config} = file:consult("../server.cfg"),
  Server = spawn(fun() -> loop(Config) end),
  logging("server.log", io_lib:format("Server Startzeit: ~p mit PID ~p ~n", [timeMilliSecond(), Server])),
  Server.

loop(Config) ->
  {ok, Lifetime} = orddict:find(lifetime, Config),

  receive
    {getmessages, PID} ->
      logging("server.log", io_lib:format("Get messages from PID: ~p ~n", [PID])),
      loop(Config);
    {dropmessage, {Message, Number}} ->
      logging("server.log", io_lib:format("Drop message {~p , ~p}~n", [Message, Number])),
      loop(Config);
    {getmsgeid, PID} ->
      logging("server.log", io_lib:format("Get message ID ~p ~n", [PID])),
      loop(Config);
    Unknown ->
      logging("server.log", io_lib:format("Got unknown Message ~p ~n", [Unknown])),
      loop(Config)
  after Lifetime * 1000 ->
    logging("server.log", io_lib:format("Server Lifetime timeout after: ~p seconds ~n", [Lifetime]))
  end.

stop() ->
    ok.

-module(server).
-import(werkzeug, [get_config_value/2,logging/2,timeMilliSecond/0,delete_last/1]).

-compile([export_all]).

start() ->
  logging("server.log", io_lib:format("Server Startzeit: ~p mit PID ~p ~n", [timeMilliSecond(), self()])),
  spawn(fun() -> loop() end).

loop() ->
  receive
    {getmessages, PID} ->
      logging("server.log", io_lib:format("Get messages from PID: ~p ~n", [PID]));
    {dropmessage, {Message, Number}} ->
      logging("server.log", io_lib:format("Drop message {~p , ~p}~n", [Message, Number]));
    {getmsgeid, PID} ->
      logging("server.log", io_lib:format("Get message ID ~p ~n", [PID]))


  end.

pid() ->
  self().


stop() ->
    ok.

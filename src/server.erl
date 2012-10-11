-module(server).
-import(werkzeug, [get_config_value/2,logging/2,timeMilliSecond/0,delete_last/1]).

-compile([export_all]).
-record(state, {config,
                current_message_number=0}).

start() ->
  {ok, Config} = file:consult("../server.cfg"),
  Server = spawn(fun() -> loop(_State = #state{config=Config}) end),
  logging("server.log", io_lib:format("Server Startzeit: ~p mit PID ~p ~n", [timeMilliSecond(), Server])),
  Server.

loop(State) ->
  {ok, Lifetime} = orddict:find(lifetime, State#state.config),

  receive
    {getmessages, PID} ->
      logging("server.log", io_lib:format("Get messages from PID: ~p ~n", [PID])),
      loop(State);

    {dropmessage, {Message, Number}} ->
      logging("server.log", io_lib:format("Drop message {~p , ~p}~n", [Message, Number])),
      loop(State);

    {getmsgeid, PID} ->
      MsgID = State#state.current_message_number,
      logging("server.log", io_lib:format("Message ID ~p give to ~p ~n", [MsgID, PID])),
      PID ! MsgID,
      loop(State#state{current_message_number=(MsgID + 1)});

    Unknown ->
      logging("server.log", io_lib:format("Got unknown Message ~p ~n", [Unknown])),
      loop(State)

  after Lifetime * 1000 ->
    logging("server.log", io_lib:format("Server Lifetime timeout after: ~p seconds ~n", [Lifetime])),
    exit(shutdown)
  end.

stop() ->
    ok.

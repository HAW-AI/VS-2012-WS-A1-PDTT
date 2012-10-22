-module(client).
-import(werkzeug, [logging/2,timeMilliSecond/0]).

-compile([export_all]).

start() ->
  {ok, Config} = file:consult("../client.cfg"),
  {servername, Servername} = lists:keyfind(servername, 1, Config),
  ClientPID = spawn(fun() -> editor(Servername, 5, Config) end),
  logging("client.log", io_lib:format("Client started at PID: ~p ~n", [ClientPID])),
  ClientPID.

editor(ServerPID, NumberOfMessagesLeft, Config) ->
  ServerPID ! {getmsgeid, self()},

  receive
    MsgID when is_integer(MsgID) ; MsgID >= 0 ->
      Message = {self(), inet:gethostname(), 2, 6, timeMilliSecond()},
      ServerPID ! {dropmessage, {Message, MsgID}},
      logging("client.log", io_lib:format("Sent message ~p to ~p ~n", [Message, ServerPID])),
      case NumberOfMessagesLeft - 1 of
        0 -> reader(ServerPID, Config);
        _ -> editor(ServerPID, NumberOfMessagesLeft - 1, Config)
      end;

    Unknown ->
      logging("client.log", io_lib:format("Got unknown Message ~p ~n", [Unknown])),
      editor(ServerPID, NumberOfMessagesLeft, Config)
  end.


reader(ServerPID, Config) ->
  ServerPID ! {getmessages, self()},
  receive
    {Message, HasMessagesLeft} ->
      logging("client.log", io_lib:format("Got Message ~p. messages left: ~p. ~n", [Message, HasMessagesLeft])),
      case HasMessagesLeft of
        true -> reader(ServerPID, Config);
        _ -> editor(ServerPID, 5, Config)
      end;

    Unknown ->
      logging("client.log", io_lib:format("Got unknown Message ~p ~n", [Unknown])),
      reader(ServerPID, Config)
  end.

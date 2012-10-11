-module(client).
-import(werkzeug, [get_config_value/2,logging/2,timeMilliSecond/0,delete_last/1]).

-compile([export_all]).

start(ServerPID) ->
  ClientPID = spawn(fun() -> editor(ServerPID, 5) end),
  ClientPID.

editor(ServerPID, NumberOfMessagesLeft) ->
  ServerPID ! {getmsgeid, self()},

  receive
    MsgID when is_integer(MsgID) ; MsgID >= 0 ->
      Message = {self(), inet:gethostname(), 2, 6, timeMilliSecond()},
      ServerPID ! {dropmessage, {Message, MsgID}},
      logging("client.log", io_lib:format("Sent message ~p to ~p ~n", [Message, ServerPID])),
      case NumberOfMessagesLeft - 1 of
        0 -> reader(ServerPID);
        _ -> editor(ServerPID, NumberOfMessagesLeft - 1)
      end;

    Unknown ->
      logging("client.log", io_lib:format("Got unknown Message ~p ~n", [Unknown])),
      editor(ServerPID, NumberOfMessagesLeft)
  end.


reader(ServerPID) ->
  ServerPID ! {getmessages, self()},
  receive
    {Message, HasMessagesLeft} ->
      logging("client.log", io_lib:format("Got Message ~p. messages left: ~p. ~n", [Message, HasMessagesLeft])),
      case HasMessagesLeft of
        true -> reader(ServerPID);
        _ -> editor(ServerPID, 5)
      end;

    Unknown ->
      logging("client.log", io_lib:format("Got unknown Message ~p ~n", [Unknown])),
      reader(ServerPID)
  end.

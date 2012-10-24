-module(client).
-import(werkzeug, [logging/2,timeMilliSecond/0]).

-compile([export_all]).

start() ->
  {ok, Config} = file:consult("../client.cfg"),
  {servername, Servername} = lists:keyfind(servername, 1, Config),
  ClientPID = spawn(fun() -> editor(Servername, 5, Config) end),
  log(io_lib:format("Client Startzeit: ~p mit PID ~p",
                                      [timeMilliSecond(), ClientPID])),
  {lifetime, Lifetime} = lists:keyfind(lifetime, 1, Config),
  timer:apply_after(timer:seconds(Lifetime), ?MODULE, stop, [Lifetime, ClientPID]),
  ClientPID.

editor(ServerPID, NumberOfMessagesLeft, Config) ->
  ServerPID ! {getmsgeid, self()},

  receive
    MsgID when is_integer(MsgID) ; MsgID >= 0 ->

      {ok, Hostname} = inet:gethostname(),
      Message = io_lib:format("Gruppe: ~B, Team: ~B; ~s-~p: ~Bte_Nachricht. Sendezeit: ~s",
                              [2, 6, Hostname, self(), MsgID, timeMilliSecond()]),

      ServerPID ! {dropmessage, {Message, MsgID}},
      log(io_lib:format("Sent message ~s to ~p", [Message, ServerPID])),
      case NumberOfMessagesLeft - 1 of
        0 -> reader(ServerPID, Config);
        _ ->
          {sendeintervall, Interval} = lists:keyfind(sendeintervall, 1, Config),
          timer:sleep(Interval * 1000),
          editor(ServerPID, NumberOfMessagesLeft - 1, set_new_interval_in_config(Config, Interval))
      end;

    Unknown ->
      log(io_lib:format("Got unknown Message ~p", [Unknown])),
      editor(ServerPID, NumberOfMessagesLeft, Config)
  end.


reader(ServerPID, Config) ->
  ServerPID ! {getmessages, self()},
  receive
    {Message, GotAllMessages} ->
      log(io_lib:format("Got Message ~s. messages left: ~p.", [Message, GotAllMessages])),
      case GotAllMessages of
        false -> reader(ServerPID, Config);
        _ -> editor(ServerPID, 5, Config)
      end;

    Unknown ->
      log(io_lib:format("Got unknown Message ~p", [Unknown])),
      reader(ServerPID, Config)
  end.

stop(Lifetime, ClientPID) ->
  log(io_lib:format("Client Lifetime timeout after: ~B seconds", [Lifetime])),
  exit(ClientPID, shutdown).

log(Msg) ->
  logging("client.log", io_lib:format("~s~n", [Msg])).

calculate_new_interval(CurrentInterval) ->
  Faktor = case random:uniform(2) of
    1 -> -0.5;
    _ -> 0.5
  end,
  NewInterval = CurrentInterval + (CurrentInterval * Faktor),

  case NewInterval < 1 of
    true -> 1;
    _ -> round(NewInterval)
  end.

set_new_interval_in_config(Config, Interval) ->
  lists:keyreplace(sendeintervall, 1, Config, {sendeintervall, calculate_new_interval(Interval)}).

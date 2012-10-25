-module(client).
-import(werkzeug, [logging/2,timeMilliSecond/0]).

-define(INITIAL_NUMBER_OF_MESSAGES_LEFT_TO_SEND, 5).
-define(PRAKTIKUMS_GRUPPE, 2).
-define(TEAM_NUMMER, 6).

-compile([export_all]).

start() ->
  {ok, Config} = file:consult("client.cfg"),
  {servername, Servername} = lists:keyfind(servername, 1, Config),
  ServerPID = global:whereis_name(Servername),
  log(io_lib:format("Servername ~s has Pid: ~s", [Servername, ServerPID])),
  {lifetime, Lifetime} = lists:keyfind(lifetime, 1, Config),
  NumClients = proplists:get_value(clients, Config),
  Clients = lists:map(fun(_ClientID) ->
      ClientPID = spawn(fun() -> editor(ServerPID, ?INITIAL_NUMBER_OF_MESSAGES_LEFT_TO_SEND, Config) end),
      log(io_lib:format("Client Startzeit: ~p mit PID ~p",
                        [timeMilliSecond(), ClientPID])),
      timer:apply_after(timer:seconds(Lifetime), ?MODULE, stop, [Lifetime, ClientPID])
    end, lists:seq(0, NumClients)),
  Clients.

editor(ServerPID, NumberOfMessagesLeft, Config) ->
  ServerPID ! {getmsgeid, self()},

  receive
    MsgID when is_integer(MsgID) ; MsgID >= 0 ->

      {ok, Hostname} = inet:gethostname(),
      Message = io_lib:format("Gruppe: ~B, Team: ~B; ~s-~p: ~Bte_Nachricht. Sendezeit: ~s",
                              [?PRAKTIKUMS_GRUPPE, ?TEAM_NUMMER, Hostname, self(), MsgID, timeMilliSecond()]),

      ServerPID ! {dropmessage, {Message, MsgID}},
      log(io_lib:format("Sent message ~s to ~p", [Message, ServerPID])),
      case NumberOfMessagesLeft - 1 of
        0 -> reader(ServerPID, Config);
        _ ->
          {sendeintervall, Interval} = lists:keyfind(sendeintervall, 1, Config),
          timer:sleep(timer:seconds(Interval)),
          editor(ServerPID, NumberOfMessagesLeft - 1, Config)
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
        _ -> editor(ServerPID,
                    ?INITIAL_NUMBER_OF_MESSAGES_LEFT_TO_SEND,
                    set_new_interval_in_config(Config))
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

set_new_interval_in_config(Config) ->
  {sendeintervall, Interval} = lists:keyfind(sendeintervall, 1, Config),
  lists:keyreplace(sendeintervall, 1, Config, {sendeintervall, calculate_new_interval(Interval)}).

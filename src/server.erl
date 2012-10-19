-module(server).
-import(werkzeug, [get_config_value/2,logging/2,timeMilliSecond/0,delete_last/1]).

-compile([export_all]).
-record(state, {config,
                current_message_number=0,
                clients=dict:new(),
                hold_back_queue=dict:new(),
                delivery_queue=queue:new()}).
-record(client_info, {last_activity,
                      last_message_id}).

start() ->
  {ok, Config} = file:consult("../server.cfg"),
  State = #state{config=Config},
  ServerPID = spawn(fun() -> loop(State) end),
  {ok, ServerName} = orddict:find(servername, State#state.config),
  register(ServerName, ServerPID),
  logging("server.log", io_lib:format("Server Startzeit: ~p mit PID ~p ~n", [timeMilliSecond(), ServerPID])),
  ServerPID.

loop(State) ->
  {ok, Lifetime} = orddict:find(lifetime, State#state.config),

  receive
    {getmessages, PID} ->
      logging("server.log", io_lib:format("Get messages from PID: ~p ~n", [PID])),
      loop(State);

    {dropmessage, {Message, Number}} ->
      logging("server.log", io_lib:format("Drop message {~p , ~p}~n", [Message, Number])),
      UpdatedHoldBackQueue = dict:append(Number, Message, State#state.hold_back_queue),
      case should_update_delivery_queue(UpdatedHoldBackQueue, State#state.delivery_queue, delivery_queue_limit(State)) of
        true -> loop(update_delivery_queue(State));
        _    -> loop(State#state{hold_back_queue=UpdatedHoldBackQueue})
      end;

    {getmsgeid, PID} ->
      MsgID = State#state.current_message_number,
      logging("server.log", io_lib:format("Message ID ~p give to ~p ~n", [MsgID, PID])),
      PID ! MsgID,
      UpdatedState = register_client_activity(PID, State),
      logging("server.log", io_lib:format("Updated State: ~p ~n", [UpdatedState])),
      loop(UpdatedState#state{current_message_number=(MsgID + 1)});

    Unknown ->
      logging("server.log", io_lib:format("Got unknown Message ~p ~n", [Unknown])),
      loop(State)

  after Lifetime * 1000 ->
    logging("server.log", io_lib:format("Server Lifetime timeout after: ~p seconds ~n", [Lifetime])),
    exit(shutdown)
  end.

stop() ->
    ok.

%% private functions
register_client_activity(Client, State) ->
  UpdatedClients =
    dict:update(Client,
                fun(Old) -> Old#client_info{last_activity=timeMilliSecond()} end,
                #client_info{last_activity=timeMilliSecond(), last_message_id=-1},
                State#state.clients),
  State#state{clients=UpdatedClients}.

should_update_delivery_queue(HoldBackQueue, DeliveryQueue, DeliveryQueueLimit) ->
  dict:size(HoldBackQueue) >= DeliveryQueueLimit/2.

delivery_queue_limit(State) ->
  orddict:find(dlqlimit, State#state.config).

first_message_id(Queue) ->
  lists:foldl(fun({Message, Number}, SmallestID) -> min(Number, SmallestID) end, void, queue:to_list(Queue)).

update_delivery_queue(State) ->
  % neue sachen aus der HoldBackQueue rausholen
  
  % differenz delivery_queue_limit und aus der DeliveryQueue rauswerfen
  % aus der HoldBackQueue elemente an DeliveryQueue anfuegen. bis zur naechsten luecke.
  % angefuegte elemente aus der HoldBackQueue entfernen
  ok.

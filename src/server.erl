-module(server).
-import(werkzeug, [get_config_value/2,logging/2,timeMilliSecond/0]).

-compile([export_all]).

-define(FIRST_MESSAGE_ID, 1).

-record(state, {config,
                current_message_number=?FIRST_MESSAGE_ID-1,
                clients=dict:new(),
                hold_back_queue=orddict:new(),
                delivery_queue=orddict:new()}).
-record(client_info, {timer_ref,
                      last_message_id}).

start() ->
  {ok, Config} = file:consult("../server.cfg"),
  State = #state{config=Config},
  ServerPID = spawn(fun() -> loop(State) end),
  {servername, ServerName} = lists:keyfind(servername, 1, State#state.config),
  register(ServerName, ServerPID),
  logging("server.log", io_lib:format("Server Startzeit: ~p mit PID ~p ~n", [timeMilliSecond(), ServerPID])),
  ServerPID.

loop(State) ->
  {lifetime, Lifetime} = lists:keyfind(lifetime, 1, State#state.config),

  receive
    {getmessages, PID} ->
      logging("server.log", io_lib:format("Get messages from PID: ~p ~n", [PID])),
      loop(State);

    {dropmessage, {Message, Number}} ->
      logging("server.log", io_lib:format("Drop message {~p , ~p}~n", [Message, Number])),
      UpdatedHoldBackQueue = orddict:append(Number, Message, State#state.hold_back_queue),
      case should_update_delivery_queue(UpdatedHoldBackQueue, delivery_queue_limit(State)) of
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

    {forget_client, PID} ->
      logging("server.log", io_lib:format("Client ~p wird vergessen! *************~n", [PID])),
      loop(State#state{clients=dict:erase(PID, State#state.clients)});

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
  {ok, TimerRef} = timer:send_after(client_lifetime(State), {forget_client, Client}),
  UpdatedClients =
    dict:update(Client,
                fun(Old) ->
                    timer:cancel(Old#client_info.timer_ref),
                    Old#client_info{timer_ref=TimerRef}
                end,
                #client_info{timer_ref=TimerRef, last_message_id=?FIRST_MESSAGE_ID-1},
                State#state.clients),
  State#state{clients=UpdatedClients}.

should_update_delivery_queue(HoldBackQueue, DeliveryQueueLimit) ->
  logging("server.log", io_lib:format("DeliveryQueueLimit: ~p ~n", [DeliveryQueueLimit])),
  orddict:size(HoldBackQueue) >= DeliveryQueueLimit div 2.

delivery_queue_limit(State) ->
  {dlqlimit, Limit} = lists:keyfind(dlqlimit, 1, State#state.config),
  Limit.

client_lifetime(State) ->
  {clientlifetime, Lifetime} = lists:keyfind(clientlifetime, 1, State#state.config),
  Lifetime.

first_message_id(DeliveryQueue) ->
  lists:foldl(fun(Number, _, SmallestID) -> min(Number, SmallestID) end, void, DeliveryQueue).

last_message_id(DeliveryQueue) ->
  lists:foldl(fun(Number, _, SmallestID) -> max(Number, SmallestID) end, void, DeliveryQueue).

extract_message_sequence(HoldBackQueue, DeliveryQueue) ->
  LastID = case last_message_id(DeliveryQueue) of
             void -> ?FIRST_MESSAGE_ID-1;
             ID   -> ID
           end,
  {_, Seq} = orddict:fold(fun(ID, Message, {LastID, Seq}) ->
                            if
                              ID == LastID+1 -> {ID, [{Message, ID} | Seq]};
                              true           -> {LastID, Seq}
                            end
                          end, {LastID, []}, HoldBackQueue),
  lists:sort(Seq).

update_delivery_queue(State) ->
  % neue sachen aus der HoldBackQueue rausholen
  MessageSequence = extract_message_sequence(State#state.hold_back_queue, State#state.delivery_queue),
  % differenz delivery_queue_limit und aus der DeliveryQueue rauswerfen
  DeliveryQueueList = orddict:to_list(State#state.delivery_queue),
  ResizedDeliveryQueueList = lists:nthtail(length(DeliveryQueueList), DeliveryQueueList),
  UpdatedDeliveryQueue = orddict:from_list(lists:append(ResizedDeliveryQueueList, MessageSequence)),
  % aus der HoldBackQueue elemente an DeliveryQueue anfuegen. bis zur naechsten luecke.
  % angefuegte elemente aus der HoldBackQueue entfernen
  UpdatedHoldBackQueue = lists:foldl(fun({_, ID}, HoldBackQueue) ->
                           orddict:erase(ID, HoldBackQueue)
                         end,
                         State#state.hold_back_queue,
                         MessageSequence),
  State#state{delivery_queue=UpdatedDeliveryQueue,
              hold_back_queue=UpdatedHoldBackQueue}.

-module(server).
-import(werkzeug, [logging/2,timeMilliSecond/0]).

% tests should be moved into a separate module
-include_lib("eunit/include/eunit.hrl").

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

  % exit server after lifetime which is specified in the config
  {lifetime, Lifetime} = lists:keyfind(lifetime, 1, Config),
  timer:apply_after(timer:seconds(Lifetime), ?MODULE, stop, [Lifetime, ServerPID]),

  ServerPID.

loop(State) ->
  {difftime, Difftime} = lists:keyfind(difftime, 1, State#state.config),

  receive
    {getmessages, PID} ->
      logging("server.log", io_lib:format("Get messages from PID: ~p ~n", [PID])),
      loop(State);

    {dropmessage, {Message, Number}} ->
      UpdatedMessage = tag_message(Message, "Hold-Back-Queue"),
      logging("server.log", io_lib:format("Drop message {~p , ~p}~n", [UpdatedMessage, Number])),
      UpdatedHoldBackQueue = orddict:append(Number, UpdatedMessage, State#state.hold_back_queue),
      case should_update_delivery_queue(UpdatedHoldBackQueue, delivery_queue_limit(State)) of
        true -> {UpdatedUpdatedHBQ, UpdatedDLQ} = update_delivery_queue(UpdatedHoldBackQueue, State#state.delivery_queue),
                loop(State#state{hold_back_queue=UpdatedUpdatedHBQ, delivery_queue=UpdatedDLQ});
        _    -> loop(State#state{hold_back_queue=UpdatedHoldBackQueue})
      end;

    {getmsgeid, PID} ->
      MsgID = State#state.current_message_number+1,
      logging("server.log", io_lib:format("Message ID ~p give to ~p ~n", [MsgID, PID])),
      PID ! MsgID,
      UpdatedState = register_client_activity(PID, State),
      logging("server.log", io_lib:format("Updated State: ~p ~n", [UpdatedState])),
      loop(UpdatedState#state{current_message_number=MsgID});

    {forget_client, PID} ->
      logging("server.log", io_lib:format("Client ~p wird vergessen! *************~n", [PID])),
      loop(State#state{clients=dict:erase(PID, State#state.clients)});

    Unknown ->
      logging("server.log", io_lib:format("Got unknown Message ~p ~n", [Unknown])),
      loop(State)

  after timer:seconds(Difftime) ->
    logging("server.log", io_lib:format("Difftime timeout. Fuer ~p Sekunden keine Nachrichten erhalten. ~n",
                                        [Difftime])),
    exit(shutdown)
  end.

stop(Lifetime, ServerPID) ->
  logging("server.log", io_lib:format("Server Lifetime timeout after: ~p seconds ~n", [Lifetime])),
  exit(ServerPID, shutdown).

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
  orddict:fold(fun(Number, _, SmallestID) -> min(Number, SmallestID) end, void, DeliveryQueue).

last_message_id(DeliveryQueue) ->
  orddict:fold(fun(Number, _, SmallestID) ->
                 if
                   SmallestID == void -> Number;
                   true               -> max(Number, SmallestID)
                 end
               end, void, DeliveryQueue).

extract_message_sequence(HoldBackQueue, DeliveryQueue, FirstID) ->
  io:format("hbq: ~p~n", [HoldBackQueue]),
  io:format("FirstID: ~p~n", [FirstID]),
  {_, Seq} = orddict:fold(fun(ID, Message, {LastID, Seq}) ->
                            io:format("ID: ~p~n", [ID]),
                            if
                              ID == LastID+1 -> {ID, [{ID, Message} | Seq]};
                              true           -> {LastID, Seq}
                            end
                          end, {FirstID-1, []}, HoldBackQueue),
  lists:sort(Seq).

update_delivery_queue(HBQ, DLQ) ->
  % neue sachen aus der HoldBackQueue rausholen
  FirstID = case last_message_id(DLQ) of
              void -> ?FIRST_MESSAGE_ID;
              ID   -> ID+1
            end,
  MsgSeq = extract_message_sequence(HBQ, DLQ, FirstID),

  % add timestamp
  %UpdatedMsgSeq = lists:map(fun({ID, Message}) -> {ID, tag_message(Message, "Delivery-Queue")} end, MsgSeq),

  % differenz delivery_queue_limit und aus der DeliveryQueue rauswerfen
  DLQList = orddict:to_list(DLQ),
  ResizedDLQList = lists:nthtail(length(DLQList), DLQList),
  UpdatedDLQ = orddict:from_list(lists:append(ResizedDLQList, MsgSeq)),

  % aus der HoldBackQueue elemente an DeliveryQueue anfuegen. bis zur naechsten luecke.
  % angefuegte elemente aus der HoldBackQueue entfernen
  UpdatedHBQ = lists:foldl(fun({ID, _}, HoldBackQueue) ->
                             orddict:erase(ID, HoldBackQueue)
                           end,
                           HBQ,
                           MsgSeq),

  {UpdatedHBQ, UpdatedDLQ}.


tag_message(Message, QueueName) ->
  io_lib:format("~p Empfangszeit in ~p: ~p~n", [Message, QueueName, timeMilliSecond()]).



% tests

extract_message_sequence_test_() ->
  HBQ = orddict:from_list([{4, "foo"}, {5, "bar"}, {3, "baz"}, {7, "nada"}]),
  DLQ = orddict:new(),

  [ ?_assertEqual([], extract_message_sequence(HBQ, DLQ, 1))
  , ?_assertEqual([{3, "baz"}, {4, "foo"}, {5, "bar"}], extract_message_sequence(HBQ, DLQ, 3))
  ].

update_delivery_queue_test_() ->
  HBQ = orddict:from_list([{2, "foo"}, {3, "bar"}, {1, "baz"}, {7, "nada"}]),
  DLQ = orddict:new(),

  [ ?_assertEqual({orddict:new(), orddict:new()},
                  update_delivery_queue(orddict:new(), orddict:new()))
  , ?_assertEqual({orddict:from_list([{7, "nada"}]), orddict:from_list([{1, "baz"}, {2, "foo"}, {3, "bar"}])},
                  update_delivery_queue(HBQ, DLQ))
  , ?_assertEqual({orddict:erase(1, HBQ), DLQ},
                  update_delivery_queue(orddict:erase(1, HBQ), DLQ))
  ].

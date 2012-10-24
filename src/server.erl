-module(server).
-import(werkzeug, [logging/2,timeMilliSecond/0]).

% tests should be moved into a separate module
-include_lib("eunit/include/eunit.hrl").

-compile([export_all]).

-define(FIRST_MESSAGE_ID, 1).

-record(state, {config,
                current_message_number=?FIRST_MESSAGE_ID-1,
                clients=dict:new(),             % ClientPID -> client_info
                hold_back_queue=orddict:new(),  % MessageID -> Message
                delivery_queue=orddict:new()}). % MessageID -> Message
-record(client_info, {timer_ref,
                      last_message_id=?FIRST_MESSAGE_ID}).

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
      UpdatedState = register_client_activity(PID, State),

      PID ! {next_message_for_client(PID, State), client_has_no_more_messages(PID, State)},
      loop(UpdatedState);

    {dropmessage, {Message, Number}} ->
      UpdatedMessage = tag_message(Message, "Hold-Back-Queue"),
      logging("server.log", io_lib:format("Drop message {~p , ~p}~n", [UpdatedMessage, Number])),
      UpdatedHoldBackQueue = orddict:append(Number, UpdatedMessage, State#state.hold_back_queue),
      case should_update_delivery_queue(UpdatedHoldBackQueue, delivery_queue_limit(State)) of
        true -> {UpdatedUpdatedHBQ, UpdatedDLQ} = update_delivery_queue(UpdatedHoldBackQueue, State#state.delivery_queue),
                TaggedDLQ = tag_messages(diff_keys(UpdatedHoldBackQueue, UpdatedUpdatedHBQ), "Delivery-Queue", UpdatedDLQ),
                loop(State#state{hold_back_queue=UpdatedUpdatedHBQ, delivery_queue=TaggedDLQ});
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
register_client_activity(ClientPID, State) ->
  {ok, TimerRef} = timer:send_after(client_lifetime(State), {forget_client, ClientPID}),
  UpdatedClients =
    dict:update(ClientPID,
                fun(Old) ->
                    timer:cancel(Old#client_info.timer_ref),
                    Old#client_info{timer_ref=TimerRef}
                end,
                #client_info{timer_ref=TimerRef},
                State#state.clients),
  State#state{clients=UpdatedClients}.

next_message_id(ClientPID, State) ->
  case dict:find(ClientPID, State#state.clients) of
    % if the ClientPID is not present return the first_message_id of the
    % DeliveryQueue because there is no reason for the Client to start at 0
    % since the DeliveryQueue has moved past 0
    error -> first_message_id(State#state.delivery_queue);
    _ ->
      {ok, Client} = dict:find(ClientPID, State#state.clients),
      Client#client_info.last_message_id + 1
  end.

next_message_for_client(ClientPID, State) ->
  % this function needs to handle two cases:
  %   - the last_message_id + 1 of the client is no longer present in the
  %     DeliveryQueue. That means we have to move on to the next available
  %     message.
  %   - the last_message_id + 1 is present
  {ok, Client} = dict:find(ClientPID, State#state.clients),
  CurrentClientMessageID = Client#client_info.last_message_id,
  DeliveryQueue = State#state.delivery_queue,
  case CurrentClientMessageID < first_message_id(DeliveryQueue) of
    true -> MessageID = first_message_id(DeliveryQueue);
    _ -> MessageID = CurrentClientMessageID
  end,
  {ok, Message} = orddict:find(MessageID, DeliveryQueue),
  Message.

client_has_no_more_messages(ClientPID, State) ->
  {ok, Client} = dict:find(ClientPID, State#state.clients),
  CurrentClientMessageID = Client#client_info.last_message_id,
  DeliveryQueue = State#state.delivery_queue,
  not lists:any(CurrentClientMessageID + 1, lists:seq(first_message_id(DeliveryQueue),
                                                      last_message_id(DeliveryQueue))).



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

extract_message_sequence(HoldBackQueue, FirstID) ->
  {_, Seq} = orddict:fold(fun(ID, Message, {LastID, Seq}) ->
                            io:format("ID: ~p~n", [ID]),
                            if
                              ID == LastID+1 -> {ID, [{ID, Message} | Seq]};
                              true           -> {LastID, Seq}
                            end
                          end, {FirstID-1, []}, HoldBackQueue),
  lists:reverse(Seq).

update_delivery_queue(HBQ, DLQ) ->
  % neue sachen aus der HoldBackQueue rausholen
  FirstID = case last_message_id(DLQ) of
              void -> ?FIRST_MESSAGE_ID;
              ID   -> ID+1
            end,
  MsgSeq = extract_message_sequence(HBQ, FirstID),

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

% add timestamp
tag_messages(IDs, QueueName, Queue) ->
  lists:foldl(fun(ID, Q) ->
        orddict:update(ID, fun(Msg) -> tag_message(Msg, QueueName) end, Q)
    end, Queue, IDs).


tag_message(Message, QueueName) ->
  io_lib:format("~p Empfangszeit in ~p: ~p~n", [Message, QueueName, timeMilliSecond()]).

diff_keys(Dict1, Dict2) ->
  sets:to_list(sets:subtract(sets:from_list(orddict:fetch_keys(Dict1)), sets:from_list(orddict:fetch_keys(Dict2)))).

% tests

extract_message_sequence_test_() ->
  HBQ = orddict:from_list([{4, "foo"}, {5, "bar"}, {3, "baz"}, {7, "nada"}]),

  [ ?_assertEqual([], extract_message_sequence(HBQ, 1))
  , ?_assertEqual([{3, "baz"}, {4, "foo"}, {5, "bar"}], extract_message_sequence(HBQ, 3))
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

diff_keys_test_() ->
  Dict = orddict:from_list([{2, "foo"}, {3, "bar"}, {1, "baz"}, {7, "nada"}]),

  [ ?_assertEqual([], diff_keys(orddict:new(), orddict:new()))
  , ?_assertEqual([], diff_keys(orddict:new(), Dict))
  ].

tag_messages_test_() ->
  Msgs = orddict:from_list([{2, "foo"}, {3, "bar"}, {1, "baz"}, {7, "nada"}]),
  TaggedMsgs = tag_messages([1,3], "Q", Msgs),

  [ ?_assertEqual(orddict:fetch_keys(Msgs), orddict:fetch_keys(TaggedMsgs))
  , ?_assertNotEqual(orddict:fetch(1, Msgs), orddict:fetch(1, TaggedMsgs))
  , ?_assertEqual(orddict:fetch(2, Msgs), orddict:fetch(2, TaggedMsgs))
  , ?_assertNotEqual(orddict:fetch(3, Msgs), orddict:fetch(3, TaggedMsgs))
  , ?_assertEqual(orddict:fetch(7, Msgs), orddict:fetch(7, TaggedMsgs))
  ].

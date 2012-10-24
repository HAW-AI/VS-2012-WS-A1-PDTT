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
  {ok, Config} = file:consult("server.cfg"),
  State = #state{config=Config},

  ServerPID = spawn(fun() -> loop(State) end),
  {servername, ServerName} = lists:keyfind(servername, 1, State#state.config),
  register(ServerName, ServerPID),

  log(io_lib:format("Server Startzeit: ~s mit PID ~p", [timeMilliSecond(), ServerPID])),

  % exit server after lifetime which is specified in the config
  {lifetime, Lifetime} = lists:keyfind(lifetime, 1, Config),
  timer:apply_after(timer:seconds(Lifetime), ?MODULE, stop, [Lifetime, ServerPID]),

  ServerPID.

loop(State) ->
  {difftime, Difftime} = lists:keyfind(difftime, 1, State#state.config),

  receive
    {getmessages, PID} ->
      log(io_lib:format("Get messages from PID: ~p", [PID])),
      UpdatedState = register_client_activity(PID, State),

      case has_client_messages_left(PID, State) of
        true -> Msg = next_message_for_client(PID, State),
                UpdatedUpdatedState = increment_last_message_id(PID, UpdatedState),
                PID ! {Msg, not has_client_messages_left(PID, UpdatedUpdatedState)},
                loop(UpdatedUpdatedState);

        _    -> loop(UpdatedState)
      end;

    {dropmessage, {Message, Number}} ->
      UpdatedMessage = tag_message(Message, "Hold-Back-Queue"),
      log(io_lib:format("Drop message ~B: ~s", [Number, UpdatedMessage])),
      UpdatedHoldBackQueue = orddict:append(Number, UpdatedMessage, State#state.hold_back_queue),
      DeliveryQueue = State#state.delivery_queue,
      ExpectedID = case last_message_id(DeliveryQueue) of
        void -> ?FIRST_MESSAGE_ID;
        ID -> ID + 1
      end,

      DLQWithoutGap =
        case should_fill_gap(UpdatedHoldBackQueue, DeliveryQueue, delivery_queue_limit(State)) of
          true -> fill_gap(UpdatedHoldBackQueue, DeliveryQueue);
          _    -> DeliveryQueue
        end,

      case should_update_delivery_queue(UpdatedHoldBackQueue, delivery_queue_limit(State), ExpectedID) of
        true -> {UpdatedUpdatedHBQ, UpdatedDLQ} = update_delivery_queue(UpdatedHoldBackQueue, DLQWithoutGap),
                TaggedDLQ = tag_messages(diff_keys(UpdatedHoldBackQueue, UpdatedUpdatedHBQ), "Delivery-Queue", UpdatedDLQ),
                loop(State#state{hold_back_queue=UpdatedUpdatedHBQ, delivery_queue=TaggedDLQ});
        _    -> loop(State#state{hold_back_queue=UpdatedHoldBackQueue})
      end;

    {getmsgeid, PID} ->
      MsgID = State#state.current_message_number+1,
      log(io_lib:format("Message ID ~B given to ~p", [MsgID, PID])),
      PID ! MsgID,
      UpdatedState = register_client_activity(PID, State),
      loop(UpdatedState#state{current_message_number=MsgID});

    {forget_client, PID} ->
      log(io_lib:format("Client ~p wird vergessen! *************", [PID])),
      loop(State#state{clients=dict:erase(PID, State#state.clients)});

    Unknown ->
      log(io_lib:format("Got unknown Message ~p", [Unknown])),
      loop(State)

  after timer:seconds(Difftime) ->
    log(io_lib:format("Difftime timeout. Fuer ~B Sekunden keine Nachrichten erhalten.",
                                        [Difftime])),
    exit(shutdown)
  end.

stop(Lifetime, ServerPID) ->
  log(io_lib:format("Server Lifetime timeout after: ~B seconds", [Lifetime])),
  exit(ServerPID, shutdown).

%% private functions
log(Msg) ->
  logging("server.log", io_lib:format("~s~n", [Msg])).


register_client_activity(ClientPID, State) ->
  {ok, TimerRef} = timer:send_after(timer:seconds(client_lifetime(State)), {forget_client, ClientPID}),
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
  MessageID = case CurrentClientMessageID < first_message_id(DeliveryQueue) of
    true -> first_message_id(DeliveryQueue);
    _ -> CurrentClientMessageID+1
  end,

  case orddict:find(MessageID, DeliveryQueue) of
    {ok, Message} -> Message;
    error         -> next_message(MessageID, DeliveryQueue)
  end.

next_message(FirstPossibleID, DLQ) ->
  lists:foldl(fun(ID, NextMsg) ->
                case NextMsg of
                  void -> case orddict:find(ID, DLQ) of
                            {ok, FoundMsg} -> FoundMsg;
                            error          -> void
                          end;
                  FoundMsg -> FoundMsg
                end
              end, void, lists:seq(FirstPossibleID, last_message_id(DLQ)+1)).

has_client_messages_left(ClientPID, State) ->
  {ok, Client} = dict:find(ClientPID, State#state.clients),
  CurrentClientMessageID = Client#client_info.last_message_id,
  DeliveryQueue = State#state.delivery_queue,

  case last_message_id(DeliveryQueue) of
    void   -> false;
    LastID -> CurrentClientMessageID < LastID
  end.

increment_last_message_id(PID, State) ->
  UpdatedClients = dict:update(PID, fun(ClientInfo) ->
        ClientInfo#client_info{last_message_id=ClientInfo#client_info.last_message_id+1}
    end, State#state.clients),

  State#state{clients=UpdatedClients}.

should_update_delivery_queue(HoldBackQueue, DeliveryQueueLimit, ExpectedID) ->
  orddict:is_key(ExpectedID, HoldBackQueue) orelse orddict:size(HoldBackQueue) > DeliveryQueueLimit div 2.

delivery_queue_limit(State) ->
  {dlqlimit, Limit} = lists:keyfind(dlqlimit, 1, State#state.config),
  Limit.

client_lifetime(State) ->
  {clientlifetime, Lifetime} = lists:keyfind(clientlifetime, 1, State#state.config),
  Lifetime.

first_message_id(DeliveryQueue) ->
  orddict:fold(fun(Number, _, SmallestID) -> min(Number, SmallestID) end, void, DeliveryQueue).

last_message_id(DeliveryQueue) ->
  orddict:fold(fun(Num, _, MaxID) ->
      case MaxID of
        void -> Num;
        _    -> max(MaxID, Num)
      end
    end, void, DeliveryQueue).

extract_message_sequence(HoldBackQueue, FirstID) ->
  {_, Seq} = orddict:fold(fun(ID, Message, {LastID, Seq}) ->
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
  UpdatedDLQ = orddict:from_list(lists:append(DLQList, MsgSeq)),

  % aus der HoldBackQueue elemente an DeliveryQueue anfuegen. bis zur naechsten luecke.
  % angefuegte elemente aus der HoldBackQueue entfernen
  UpdatedHBQ = lists:foldl(fun({ID, _}, HoldBackQueue) ->
                             orddict:erase(ID, HoldBackQueue)
                           end,
                           HBQ,
                           MsgSeq),

  {UpdatedHBQ, UpdatedDLQ}.


should_fill_gap(HBQ, DLQ, DLQLimit) ->
  case orddict:size(HBQ) > DLQLimit div 2 of
    false -> false;
    _     ->
      FirstHBQID = case last_message_id(DLQ) of
        void -> ?FIRST_MESSAGE_ID;
        ID   -> ID+1
      end,

      not orddict:is_key(FirstHBQID)
  end.

fill_gap(HBQ, DLQ) ->
  FirstGapID = case last_message_id(DLQ) of
    void -> ?FIRST_MESSAGE_ID;
    FID  -> FID+1
  end,

  LastGapID = case first_message_id(HBQ) of
    void -> ?FIRST_MESSAGE_ID;
    LID  -> LID-1
  end,

  case FirstGapID == LastGapID of
    true -> DLQ;
    _    -> Msg = io_lib:format("***Fehlernachricht fuer Nachrichtennummern ~B bis ~B um ~s",
                                [FirstGapID, LastGapID, timeMilliSecond()]),
            orddict:append(LastGapID, Msg, DLQ)
  end.


% add timestamp
tag_messages(IDs, QueueName, Queue) ->
  lists:foldl(fun(ID, Q) ->
        orddict:update(ID, fun(Msg) -> tag_message(Msg, QueueName) end, Q)
    end, Queue, IDs).


tag_message(Message, QueueName) ->
  io_lib:format("~s Empfangszeit in ~s: ~s", [Message, QueueName, timeMilliSecond()]).

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
  DLQ2 = orddict:from_list([{0, "lala"}]),

  [ ?_assertEqual({orddict:new(), orddict:new()},
                  update_delivery_queue(orddict:new(), orddict:new()))
  , ?_assertEqual({orddict:from_list([{7, "nada"}]), orddict:from_list([{1, "baz"}, {2, "foo"}, {3, "bar"}])},
                  update_delivery_queue(HBQ, DLQ))
  , ?_assertEqual({orddict:erase(1, HBQ), DLQ},
                  update_delivery_queue(orddict:erase(1, HBQ), DLQ))
  , ?_assertEqual({orddict:from_list([{7, "nada"}]), orddict:from_list([{2, "foo"}, {3, "bar"}, {1, "baz"}, {0, "lala"}])},
                  update_delivery_queue(HBQ, DLQ2))
  ].

should_update_delivery_queue_test_() ->
  HBQ = orddict:from_list([{2, "foo"}, {3, "bar"}, {1, "baz"}, {7, "nada"}]),

  [ ?_assertNot(should_update_delivery_queue(HBQ, 31, 4))
  , ?_assert(should_update_delivery_queue(HBQ, 31, 1))
  , ?_assert(should_update_delivery_queue(HBQ, 31, 2))
  , ?_assert(should_update_delivery_queue(HBQ, 4, 4))
  , ?_assert(should_update_delivery_queue(HBQ, 7, 4))
  , ?_assertNot(should_update_delivery_queue(HBQ, 8, 4))
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

next_message_for_client_test_() ->
  DLQ = orddict:from_list([{2, "foo"}, {3, "bar"}, {5, "baz"}]),
  PID = spawn(fun() -> timer:sleep(infinity) end),
  Clients = dict:from_list([{PID, #client_info{timer_ref=void, last_message_id=1}}]),
  State = #state{delivery_queue=DLQ, clients=Clients},
  Clients2 = dict:update(PID, fun(Info) -> Info#client_info{last_message_id=3} end, Clients),
  State2 = State#state{clients=Clients2},

  [ ?_assertEqual("foo", next_message_for_client(PID, State))
  , ?_assertEqual("baz", next_message_for_client(PID, State2))
  ].

has_client_messages_left_test_() ->
  DLQ = orddict:from_list([{2, "foo"}, {3, "bar"}, {5, "baz"}]),
  PID = spawn(fun() -> timer:sleep(infinity) end),
  Clients = dict:from_list([{PID, #client_info{timer_ref=void, last_message_id=1}}]),
  State = #state{delivery_queue=DLQ, clients=Clients},
  Clients2 = dict:update(PID, fun(Info) -> Info#client_info{last_message_id=3} end, Clients),
  State2 = State#state{clients=Clients2},
  Clients3 = dict:update(PID, fun(Info) -> Info#client_info{last_message_id=5} end, Clients),
  State3 = State#state{clients=Clients3},

  [ ?_assert(has_client_messages_left(PID, State))
  , ?_assert(has_client_messages_left(PID, State2))
  , ?_assertNot(has_client_messages_left(PID, State3))
  ].

increment_last_message_id_test_() ->
  PID = spawn(fun() -> timer:sleep(infinity) end),
  State = #state{clients=dict:from_list([{PID, #client_info{last_message_id=2}}])},
  UpdatedState = increment_last_message_id(PID, State),
  UpdatedClient = dict:fetch(PID, UpdatedState#state.clients),

  [ ?_assertEqual(3, UpdatedClient#client_info.last_message_id)
  ].

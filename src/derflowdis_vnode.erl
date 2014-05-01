-module(derflowdis_vnode).
-behaviour(riak_core_vnode).
-include("derflowdis.hrl").

-export([bind/2,
         bind/3,
         read/1,
	 waitNeeded/1,
         declare/1,
	 get_new_id/0,
	 put/4,
	 execute_and_put/5]).

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

-ignore_xref([
             start_vnode/1
             ]).

-record(state, {partition, clock, table}).
-record(dv, {value, next, waitingThreads = [], creator, lazy= false, bounded = false}). 

%% Extrenal API
bind(Id, Value) -> 
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(Id)}),
    PrefList = riak_core_apl:get_primary_apl(DocIdx, 1, derflowdis),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, {bind, Id, Value}, derflowdis_vnode_master).

bind(Id, Function, Args) -> 
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(Id)}),
    PrefList = riak_core_apl:get_primary_apl(DocIdx, 1, derflowdis),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, {bind, Id, Function, Args}, derflowdis_vnode_master).

read(Id) -> 
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(Id)}),
    PrefList = riak_core_apl:get_primary_apl(DocIdx, 1, derflowdis),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, {read, Id}, derflowdis_vnode_master).

declare(Id) -> 
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(Id)}),
    PrefList = riak_core_apl:get_primary_apl(DocIdx, 1, derflowdis),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, {declare, Id}, derflowdis_vnode_master).

get_new_id() -> 
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(now())}),
    PrefList = riak_core_apl:get_primary_apl(DocIdx, 1, derflowdis),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, get_new_id, derflowdis_vnode_master).

waitNeeded(Id) -> 
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(Id)}),
    PrefList = riak_core_apl:get_primary_apl(DocIdx, 1, derflowdis),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, {waitNeeded, Id}, derflowdis_vnode_master).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) ->
    Table=string:concat(integer_to_list(Partition), "dvstore"),
    Table_atom=list_to_atom(Table),
    ets:new(Table_atom, [set, named_table, public, {write_concurrency, true}]),
    {ok, #state { partition=Partition, clock=0, table=Table_atom }}.

handle_command(get_new_id, _From, State=#state{partition=Partition}) ->
    Clock = State#state.clock +1,
    {reply, {Clock,Partition}, State#state{clock=Clock}};

handle_command({declare, Id}, _From, State=#state{table=Table}) ->
    V = #dv{value=empty, next=empty},
    ets:insert(Table, {Id, V}),
    {reply, {id, Id}, State};

handle_command({bind, Id, F, Arg}, _From, State=#state{partition=Partition, table=Table}) ->
    Next = State#state.clock+1,
    NextKey={Next, Partition},
    declare(NextKey),
    %ets:insert(Table, {Next, #dv{value=empty, next=empty}}),
    spawn(derflowdis_vnode, execute_and_put, [F, Arg, NextKey, Id, Table]),
    {reply, {id, NextKey}, State#state{clock=Next}};

handle_command({bind,Id, Value}, _From, State=#state{partition=Partition, table=Table}) ->
    Next = State#state.clock+1,
    NextKey={Next, Partition},
    declare(NextKey),
    %ets:insert(Table, {Next, #dv{value=empty, next=empty}}),
    spawn(derflowdis_vnode, put, [Value, NextKey, Id, Table]),
    {reply, {id, NextKey}, State#state{clock=Next}};
%%%What if the Key does not exist in the map?%%%
%handle_command({read,X}, From, State=#state{table=Table}) ->
%    [{_Key,V}] = ets:lookup(Table, X),
%    Value = V#dv.value,
%    Bounded = V#dv.bounded,
    %%%Need to distinguish that value is not calculated or is the end of a list%%%
%    if Bounded == true ->
%	{reply, {Value, V#dv.next}, State};
%    true ->
%	WT = lists:append(V#dv.waitingThreads, [From]),
%	V1 = V#dv{waitingThreads=WT},
%	ets:delete(Table, X),
%	ets:insert(Table, {X, V1}),
%	{noreply, State}
%    end;

handle_command({waitNeeded, Id}, From, State=#state{table=Table}) ->
    [{_Key,V}] = ets:lookup(Table, Id),
    case V#dv.waitingThreads of [_H|_T] ->
        {reply, ok, State};
        _ ->
        ets:insert(Table, {Id, V#dv{lazy=true, creator=From}}),
        {noreply, State}
    end;


handle_command({read,X}, From, State=#state{table=Table}) ->
        [{_Key,V}] = ets:lookup(Table, X),
        Value = V#dv.value,
        Bounded = V#dv.bounded,
        Creator = V#dv.creator,
        Lazy = V#dv.lazy,
        %%%Need to distinguish that value is not calculated or is the end of a list%%%
        if Bounded == true ->
          {reply, {Value, V#dv.next}, State};
         true ->
          if Lazy == true ->
                WT = lists:append(V#dv.waitingThreads, [From]),
                V1 = V#dv{waitingThreads=WT},
                ets:insert(Table, {X, V1}),
                gen_server:reply(Creator, ok),
                {noreply, State};
          true ->
                WT = lists:append(V#dv.waitingThreads, [From]),
                V1 = V#dv{waitingThreads=WT},
                ets:insert(Table, {X, V1}),
                {noreply, State}
          end
        end;




handle_command(Message, _Sender, State) ->
    ?PRINT({unhandled_command, Message}),
    {noreply, State}.

handle_handoff_command(_Message, _Sender, State) ->
    {noreply, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(_Data, State) ->
    {reply, ok, State}.

encode_handoff_item(_ObjectName, _ObjectValue) ->
    <<>>.

is_empty(State) ->
    {true, State}.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%Internal functions

put(Value, Next, Key, Table) ->
    [{_Key,V}] = ets:lookup(Table, Key),
    Threads = V#dv.waitingThreads,
    V1 = #dv{value= Value, next =Next, lazy=false, bounded= true},
    ets:insert(Table, {Key, V1}),
    replyToAll(Threads, Value, Next, Key).

execute_and_put(F, Arg, Next, Key, Table) ->
    [{_Key,V}] = ets:lookup(Table, Key),
    Threads = V#dv.waitingThreads,
    Value = F(Arg),
    V1 = #dv{value= Value, next =Next, lazy=false,bounded= true},
    ets:insert(Table, {Key, V1}),
    replyToAll(Threads, Value, Next, Key).

replyToAll([], _Value, _Nexti, _Id) ->
    ok;

replyToAll([H|T], Value, Next, Id) ->
    {server, undefined,{Address, Ref}} = H,
    gen_server:reply({Address, Ref},{Value,Next}),
    replyToAll(T, Value, Next, Id).


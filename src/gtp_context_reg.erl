%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_reg).

-behaviour(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/1]).
-export([registry/1, register/4, register_new/4, update/5, unregister/4,
	 lookup/2, select/2,
	 match_key/3, match_keys/3,
	 await_unreg/2]).
-export([all/1]).
-export([alloc_tei/2, lookup_tei/3]).
-export([is_empty/1, handoff_command/3, handoff_data/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("include/ergw.hrl").

-record(state, {partition, tid, prefix, pids, await_unreg}).

-define(MAX_TRIES, 32).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Partition) ->
    gen_server:start_link(?MODULE, [Partition], []).

registry(Server) ->
    gen_server:call(Server, registry).

lookup({_, TID}, Key) when is_tuple(Key) ->
    case ets:lookup(TID, Key) of
	[{Key, Value}] ->
	    Value;
	_ ->
	    undefined
    end.

select({_, TID}, Key) ->
    ets:select(TID, [{{Key, '$1'},[],['$1']}]).

match_key(Registry, #gtp_port{name = Name}, Key) ->
    select(Registry, {Name, Key}).

match_keys(_, _, []) ->
    throw({error, not_found});
match_keys(Registry, Port, [H|T]) ->
    case match_key(Registry, Port, H) of
	[_|_] = Match ->
	    Match;
	_ ->
	    match_keys(Registry, Port, T)
    end.

register({Server, _}, Keys, Handler, Pid)
  when is_list(Keys), is_atom(Handler), is_pid(Pid) ->
    gen_server:call(Server, {register, Keys, Handler, Pid}).

register_new({Server, _}, Keys, Handler, Pid)
  when is_list(Keys), is_atom(Handler), is_pid(Pid) ->
    gen_server:call(Server, {register_new, Keys, Handler, Pid}).

update({Server, _}, Delete, Insert, Handler, Pid)
  when is_list(Delete), is_list(Insert), is_atom(Handler), is_pid(Pid) ->
    gen_server:call(Server, {update, Delete, Insert, Handler, Pid}).

unregister({Server, _}, Keys, Handler, Pid)
  when is_list(Keys), is_atom(Handler), is_pid(Pid) ->
    gen_server:call(Server, {unregister, Keys, Handler, Pid}).

all({_, TID}) ->
    ets:tab2list(TID).

await_unreg({Server, _}, Key) ->
    gen_server:call(Server, {await_unreg, Key}, 1000).

%% with_keyfun/2
with_keyfun(#request{gtp_port = Port}, Fun) ->
    with_keyfun(Port, Fun);
with_keyfun(#gtp_port{name = Name} = Port, Fun) ->
    Fun(Name, gtp_context:port_teid_key(Port, _));
with_keyfun(#pfcp_ctx{name = Name} = PCtx, Fun) ->
    Fun(Name, ergw_pfcp:ctx_teid_key(PCtx, _)).

%% alloc_tei/2
alloc_tei(Registry, Port) ->
    with_keyfun(Port, alloc_tei(Registry, _, _)).

%% alloc_tei/3
alloc_tei({Server, _}, Name, KeyFun)
  when is_function(KeyFun, 1) ->
    gen_server:call(Server, {alloc_tei, Name, KeyFun}).

%% lookup_tei/3
lookup_tei(Registry, Port, TEI) ->
    with_keyfun(Port, lookup_tei(Registry, _, TEI, _)).

%% lookup_tei/4
lookup_tei(Registry, _Name, TEI, KeyFun) ->
    lookup(Registry, KeyFun(TEI)).

is_empty({_, TID}) ->
    ?LOG(info, "ETS Size ~p -> ~p", [TID, ets:info(TID, size)]),
    ets:info(TID, size) == 0.

handoff_command({_, TID}, FoldFun, AccIn) ->
    MS = ets:fun2ms(fun({{_,tei}, _} = V) -> V end),
    ?LOG(info, "ETS select ~p -> ~p", [TID, ets:select(TID, MS)]),
    ?LOG(info, "ETS all ~p -> ~p", [TID, ets:tab2list(TID)]),
    handoff_command_fold(ets:select(TID, MS, 1), FoldFun, AccIn).

handoff_command_fold('$end_of_table', _, Acc) ->
    Acc;
handoff_command_fold({[{Key, Val}], Cont}, FoldFun, AccIn) ->
    AccOut = FoldFun(Key, rand:export_seed_s(Val), AccIn),
    handoff_command_fold(ets:select(Cont), FoldFun, AccOut).

handoff_data({_, TID}, Key, Data) ->
    ets:insert(TID, {Key, rand:seed(Data)}),
    ok.

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([Partition]) ->
    process_flag(trap_exit, true),

    TID = ets:new(?MODULE, [ordered_set, public, {keypos, 1}]),
    State = #state{
	       partition = Partition,
	       tid = TID,
	       prefix = init_tei_prefix(Partition),
	       pids = #{},
	       await_unreg = #{}
	      },
    {ok, State}.

handle_call(registry, _From, #state{tid = TID} = State) ->
    Registry = {self(), TID},
    {reply, {ok, Registry}, State};

handle_call({register, Keys, Handler, Pid}, _From, State) ->
    handle_add_keys(fun ets:insert/2, Keys, Handler, Pid, State);

handle_call({register_new, Keys, Handler, Pid}, _From, State) ->
    handle_add_keys(fun ets:insert_new/2, Keys, Handler, Pid, State);

handle_call({update, Delete, Insert, Handler, Pid}, _From, State) ->
    lists:foreach(fun(Key) -> delete_key(Key, Pid, State) end, Delete),
    NKeys = ordsets:union(ordsets:subtract(get_pid(Pid, State), Delete), Insert),
    handle_add_keys(fun ets:insert/2, Insert, Handler, Pid, update_pid(Pid, NKeys, State));

handle_call({unregister, Keys, _Handler, Pid}, _From, State0) ->
    State = delete_keys(Keys, Pid, State0),
    {reply, ok, State};

handle_call({await_unreg, Pid}, From, #state{pids = Pids, await_unreg = AWait} = State0)
  when is_pid(Pid) ->
    case maps:is_key(Pid, Pids) of
	true ->
	    State = State0#state{
		      await_unreg =
			  maps:update_with(Pid, fun(V) -> [From|V] end, [From], AWait)},
	    {noreply, State};
	_ ->
	    {reply, ok, State0}
    end;

handle_call({alloc_tei, Name, KeyFun}, _From, #state{tid = TID} = State) ->
    RndStateKey = {Name, tei},
    RndState = maybe_init_rnd(ets:lookup(TID, RndStateKey)),
    Reply = alloc_tei(RndStateKey, RndState, KeyFun, ?MAX_TRIES, State),
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, _Reason}, State0) ->
    Keys = get_pid(Pid, State0),
    State = delete_keys(Keys, Pid, State0),
    {noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_pid(Pid, #state{pids = Pids}) ->
    maps:get(Pid, Pids, []).

update_pid(Pid, Keys, #state{pids = Pids} = State) ->
    State#state{pids = Pids#{Pid => Keys}}.

delete_pid(Pid, #state{pids = Pids} = State) ->
    notify_unregister(Pid, State#state{pids = maps:remove(Pid, Pids)}).

notify_unregister(Pid, #state{await_unreg = AWait} = State) ->
    Reply = maps:get(Pid, AWait, []),
    lists:foreach(fun(From) -> gen_server:reply(From, ok) end, Reply),
    State#state{await_unreg = maps:remove(Pid, AWait)}.

handle_add_keys(Fun, Keys, Handler, Pid, #state{tid = TID} = State) ->
    RegV = {Handler, Pid},
    case Fun(TID, [{Key, RegV} || Key <- Keys]) of
	true ->
	    link(Pid),
	    NKeys = ordsets:union(Keys, get_pid(Pid, State)),
	    {reply, ok, update_pid(Pid, NKeys, State)};
	_ ->
	    {reply, {error, duplicate}, State}
    end.

delete_keys(Keys, Pid, State) ->
    lists:foreach(fun(Key) -> delete_key(Key, Pid, State) end, Keys),
    case ordsets:subtract(get_pid(Pid, State), Keys) of
	[] ->
	    unlink(Pid),
	    delete_pid(Pid, State);
	Rest ->
	    update_pid(Pid, Rest, State)
    end.

%% this is not the same a ets:take, the object will only
%% be delete if Key and Pid match.....
delete_key(Key, Pid, #state{tid = TID}) ->
    case ets:lookup(TID, Key) of
	[{Key, {_, Pid}}] ->
	    ets:take(TID, Key);
	Other ->
	    Other
    end.

%%====================================================================
%% TEI registry
%%====================================================================

maybe_init_rnd([]) ->
    rand:seed_s(exrop);
maybe_init_rnd([{_, RndState}]) ->
    RndState.

init_tei_prefix(Partition) ->
    {ok, CHBin} = riak_core_ring_manager:get_chash_bin(),
    NumPartitions = chashbin:num_partitions(CHBin),
    PrefixLen = round(math:log2(NumPartitions)),
    Prefix = riak_core_ring_util:hash_to_partition_id(Partition, NumPartitions)
	bsl (32 - PrefixLen),
    Mask = 16#ffffffff bsr PrefixLen,
    ?LOG(debug, "Prefix: 0x~8.16.0b, Mask: 0x~8.16.0b", [Prefix, Mask]),
    {Prefix, Mask}.

alloc_tei(_RndStateKey, _RndState, _KeyFun, 0, _State) ->
    {error, no_tei};
alloc_tei(RndStateKey, RndState0, KeyFun, Cnt,
	  #state{tid = TID, prefix = {Prefix, Mask}} = State) ->
    {TEI0, RndState} = rand:uniform_s(16#fffffffe, RndState0),
    TEI = Prefix + (TEI0 band Mask),
    case ets:lookup(TID, KeyFun(TEI)) of
	[] ->
	    true = ets:insert(TID, {RndStateKey, RndState}),
	    {ok, TEI};
	_ ->
	    alloc_tei(RndStateKey, RndState, KeyFun, Cnt - 1, State)
    end.

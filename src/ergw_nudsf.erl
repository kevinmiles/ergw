%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% simple implementation of 3GPP TS 29.598 Nudsf service
%% - functional API according to TS
%% - not optimized for anything

-module(ergw_nudsf).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/0,
	 get/2, get/3,
	 search/1,
	 create/3, create/4,
	 put/3, put/4,
	 delete/2, delete/3,
	 all/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-record(entry, {meta, blocks}).

%%%=========================================================================
%%%  API
%%%=========================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% TS 29.598, 5.2.2.2 Query

get(record, RecordId) ->
    gen_server:call(?SERVER, {get, record, RecordId});

get(meta, RecordId) ->
    gen_server:call(?SERVER, {get, meta, RecordId});

get(blocks, RecordId) ->
    gen_server:call(?SERVER, {get, blocks, RecordId}).

get(block, RecordId, BlockId) ->
    gen_server:call(?SERVER, {get, block, RecordId, BlockId}).

%% TS 29.598, 5.2.2.2.6	Search

search(Filter) ->
    gen_server:call(?SERVER, {search, Filter}).

%% TS 29.598, 5.2.2.3 Create

create(RecordId, Meta, Blocks) ->
    gen_server:call(?SERVER, {create, record, RecordId, Meta, Blocks}).

create(block, RecordId, BlockId, Block) ->
    gen_server:call(?SERVER, {create, block, RecordId, BlockId, Block}).

%% TS 29.598, 5.2.2.4 Update

put(record, RecordId, Meta, Blocks) ->
    gen_server:call(?SERVER, {put, record, RecordId, Meta, Blocks});

put(block, RecordId, BlockId, Block) ->
    gen_server:call(?SERVER, {put, block, RecordId, BlockId, Block}).

put(meta, RecordId, Meta) ->
    gen_server:call(?SERVER, {put, meta, RecordId, Meta}).

%% TS 29.598, 5.2.2.5 Delete

delete(record, RecordId) ->
    gen_server:call(?SERVER, {delete, record, RecordId}).

delete(block, RecordId, BlockId) ->
    gen_server:call(?SERVER, {delete, block, RecordId, BlockId}).

all() ->
    gen_server:call(?SERVER, all).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    {ok, #{}}.

handle_call({get, record, RecordId}, _Form, State)
  when is_map_key(RecordId, State) ->
    Entry = maps:get(RecordId, State),
    Reply = {ok, Entry#entry.meta, Entry#entry.blocks},
    {reply, Reply, State};

handle_call({get, meta, RecordId}, _Form, State)
  when is_map_key(RecordId, State) ->
    Entry = maps:get(RecordId, State),
    Reply = {ok, Entry#entry.meta},
    {reply, Reply, State};

handle_call({get, blocks, RecordId}, _Form, State)
  when is_map_key(RecordId, State) ->
    Entry = maps:get(RecordId, State),
    Reply = {ok, Entry#entry.blocks},
    {reply, Reply, State};

handle_call({get, blocks, _}, _Form, State) ->
    Reply = {error, not_found},
    {reply, Reply, State};

handle_call({get, block, RecordId, BlockId}, _Form, State)
  when is_map_key(RecordId, State) ->
    Entry = maps:get(RecordId, State),
    Reply = case Entry#entry.blocks of
		#{BlockId := Block} ->
		    {ok, Block};
		_ ->
		    {error, not_found}
	    end,
    {reply, Reply, State};

handle_call({get, block, _, _}, _Form, State) ->
    Reply = {error, not_found},
    {reply, Reply, State};

handle_call({search, Filter}, _Form, State) ->
    try
	ResM = maps:filter(search(_, _, Filter), State),
	{reply, maps:keys(ResM), State}
    catch
	Class:Error:ST ->
	    ?LOG(error, "Nudsf search failed with ~p:~p (~p)",
		 [Class, Error, ST]),
	    {reply, {error, invalid_filter}, State}
    end;

handle_call({create, record, RecordId, _, _, _}, _Form, State)
  when is_map_key(RecordId, State) ->
    Reply = {error, already_exists},
    {reply, Reply, State};

handle_call({create, record, RecordId, Meta, Blocks}, _Form, State0) ->
    Entry = #entry{meta = Meta, blocks = Blocks},
    State = maps:put(RecordId, Entry, State0),
    {reply, ok, State};

handle_call({create, block, RecordId, _, _, _}, _Form, State)
  when is_map_key(RecordId, State) ->
    Reply = {error, already_exists},
    {reply, Reply, State};

handle_call({create, block, RecordId, BlockId, Block}, _Form, State0)
  when is_map_key(RecordId, State0) ->
    Entry0 = maps:get(RecordId, State0),
    Entry = Entry0#entry{blocks = maps:put(BlockId, Block, Entry0#entry.blocks)},
    State = maps:put(RecordId, Entry, State0),
    {reply, ok, State};

handle_call({create, block, _, _, _}, _Form, State) ->
    Reply = {error, not_found},
    {reply, Reply, State};

handle_call({put, record, RecordId, Meta, Blocks}, _Form, State0)
  when is_map_key(RecordId, State0) ->
    Entry = maps:get(RecordId, State0),
    State = maps:put(RecordId, Entry#entry{meta = Meta, blocks = Blocks}, State0),
    {reply, ok, State};

handle_call({put, meta, RecordId, Meta}, _Form, State0)
  when is_map_key(RecordId, State0) ->
    Entry = maps:get(RecordId, State0),
    State = maps:put(RecordId, Entry#entry{meta = Meta}, State0),
    {reply, ok, State};

handle_call({put, _, _, _}, _Form, State) ->
    Reply = {error, not_found},
    {reply, Reply, State};

handle_call({put, block, RecordId, BlockId, Block}, _Form, State0)
  when is_map_key(RecordId, State0) ->
    Entry0 = maps:get(RecordId, State0),
    case maps:is_key(BlockId, Entry0#entry.blocks) of
	true ->
	    Entry = Entry0#entry{blocks = maps:put(BlockId, Block, Entry0#entry.blocks)},
	    State = maps:put(RecordId, Entry, State0),
	    {reply, ok, State};
	_ ->
	    Reply = {error, not_found},
	    {reply, Reply, State0}
    end;

handle_call({put, block, _, _, _}, _Form, State) ->
    Reply = {error, not_found},
    {reply, Reply, State};

handle_call({delete, record, RecordId}, _Form, State0)
  when is_map_key(RecordId, State0) ->
    State = maps:remove(RecordId, State0),
    {reply, ok, State};

handle_call({delete, record, _}, _Form, State) ->
    Reply = {error, not_found},
    {reply, Reply, State};

handle_call({delete, block, RecordId, BlockId}, _Form, State0)
  when is_map_key(RecordId, State0) ->
    Entry0 = maps:get(RecordId, State0),
    case maps:is_key(BlockId, Entry0#entry.blocks) of
	true ->
	    Entry = Entry0#entry{blocks = maps:remove(BlockId, Entry0#entry.blocks)},
	    State = maps:put(RecordId, Entry, State0),
	    {reply, ok, State};
	_ ->
	    Reply = {error, not_found},
	    {reply, Reply, State0}
    end;

handle_call({delete, block, _, _}, _Form, State) ->
    Reply = {error, not_found},
    {reply, Reply, State};

handle_call(all, _From, State) ->
    {reply, State, State};

handle_call(Request, _From, State) ->
    Reply = {error, {badarg, Request}},
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

search(_, #entry{meta = Meta}, Expr) ->
    search_expr(Expr, maps:get(tags, Meta, #{})).

search_expr(#{'cond' := Cond, units := Units}, Tags) ->
    search_expr(Cond, Units, Tags);

search_expr(#{tag := Tag, value := Value} = Cond, Tags) ->
    search_cond(maps:get(Tag, Tags, undefined), Value, maps:get(op, Cond, 'EQ')).

search_expr('NOT', [Expr], Tags) ->
    not search_expr(Expr, Tags);

search_expr('OR', [], _) ->
    false;
search_expr('OR', [Expr|Units], Tags) ->
    search_expr(Expr, Tags) orelse search_expr('OR', Units, Tags);

search_expr('AND', [], _) ->
    true;
search_expr('AND', [Expr|Units], Tags) ->
    search_expr(Expr, Tags) andalso search_expr('OR', Units, Tags).

search_cond(V1, V2, 'EQ')  -> V1 =:= V2;
search_cond(V1, V2, 'NEQ') -> V1 =/= V2;
search_cond(V1, V2, 'GT')  -> V1 > V2;
search_cond(V1, V2, 'GTE') -> V1 >= V2;
search_cond(V1, V2, 'LT')  -> V1 < V2;
search_cond(V1, V2, 'LTE') -> V1 =< V2.
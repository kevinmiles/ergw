%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_coverage_fsm).
-behaviour(riak_core_coverage_fsm).

-export([start_link/4, start/2]).
-export([init/2, process_results/2, finish/2]).

-ignore_xref([start_link/4]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include_lib("kernel/include/logger.hrl").

-record(state, {req_id, from, request, accum = []}).

%%====================================================================
%% API
%%====================================================================

start_link(ReqId, From, Request, Timeout) ->
    riak_core_coverage_fsm:start_link(?MODULE, {pid, ReqId, From},
				      [ReqId, From, Request, Timeout]).

start(Request, Timeout) ->
    ReqId = erlang:phash2(erlang:monotonic_time()),
    {ok, _} = gtp_context_coverage_fsm_sup:start_fsm([ReqId, self(), Request, Timeout]),
    receive
	{ReqId, Val} -> Val
    end.

%%====================================================================
%% riak_core_coverage_fsm API
%%====================================================================

init(_, [ReqId, From, Request, Timeout]) ->
    State = #state{req_id=ReqId, from=From, request=Request},
    {Request, allup, 1, 1, ergw, gtp_context_vnode_master, Timeout, State}.

process_results({{_ReqId, {Partition, Node}}, Data},
		State=#state{accum=Accum}) ->
    NewAccum = [{Partition, Node, Data}|Accum],
    {done, State#state{accum=NewAccum}};

process_results(Other, State=#state{}) ->
    ?LOG(warning, "unknown process_results message ~p", [Other]),
    {stop, {error, {unknown_msg, Other}}, State}.

finish(clean, S=#state{req_id=ReqId, from=From, accum=Accum}) ->
    From ! {ReqId, {ok, Accum}},
    {stop, normal, S};

finish({error, Reason}, S=#state{req_id=ReqId, from=From, accum=Accum}) ->
    ?LOG(warning,"Coverage query failed! Reason: ~p", [Reason]),
    From ! {ReqId, {partial, Reason, Accum}},
    {stop, normal, S}.

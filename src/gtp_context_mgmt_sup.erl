%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_mgmt_sup).

-behaviour(supervisor).

%% API
-export([start_link/1, new/1, stop/1, get_workers/1]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Partition) ->
    supervisor:start_link(?MODULE, [Partition]).

new(Partition) ->
    gtp_context_sup_sup:new(Partition).

stop(Id) ->
    gtp_context_sup_sup:stop(Id).

get_workers(MgmtSup) ->
    lists:foldl(
      fun({Id, Child, _, _}, M) when Id =:= gtp_context_reg ->
	      {ok, Registry} = gtp_context_reg:registry(Child),
	      M#{Id => Registry};
	 ({Id, Child, _, _}, M) ->
	      M#{Id => Child}
      end,
      #{}, supervisor:which_children(MgmtSup)).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Partition]) ->
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    RegSpec = #{id =>       gtp_context_reg,
		start =>    {gtp_context_reg, start_link, [Partition]},
		restart =>  permanent,
		shutdown => 1000,
		type =>     worker,
		modules =>  [gtp_context_reg]},
    SupSpec = #{id =>       gtp_context_sup,
		start =>    {gtp_context_sup, start_link, []},
		restart =>  permanent,
		shutdown => 1000,
		type =>     supervisor,
		modules =>  [gtp_context_sup]},
    {ok, {Flags, [RegSpec, SupSpec]}}.

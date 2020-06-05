%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_mgmt_sup).

-behaviour(supervisor).

%% API
-export([start_link/1, new/6, new/7]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Partition) ->
    supervisor:start_link(?MODULE, [Partition]).

new(Sup, Port, TEI, Version, Interface, IfOpts) ->
    Opts = [{hibernate_after, 500},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    new(Sup, Port, TEI, Version, Interface, IfOpts, Opts).

new(Sup, Port, TEI, Version, Interface, IfOpts, Opts) ->
    ?LOG(debug, "new(~p)", [[Sup, Port, TEI, Version, Interface, IfOpts, Opts]]),
    supervisor:start_child(Sup, [Port, TEI, Version, Interface, IfOpts, Opts]).

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

%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_sup_sup).

-behaviour(supervisor).

%% API
-export([start_link/1, new/0, stop/1]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Partition) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Partition]).

new() ->
    supervisor:start_child(?SERVER, []).

stop(Id) ->
    supervisor:terminate_child(?SERVER, Id).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Partition]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 5, period => 10},
    Spec = #{id =>       gtp_context_mgmt_sup,
	     start =>    {gtp_context_mgmt_sup, start_link, [Partition]},
	     restart =>  temporary,
	     shutdown => 1000,
	     type =>     supervisor,
	     modules =>  [gtp_context_mgmt_sup]},
    {ok, {Flags, [Spec]}}.

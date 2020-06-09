%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_coverage_fsm_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_fsm/1]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_fsm(Args) ->
    supervisor:start_child(?SERVER, Args).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Spec = #{id       => gtp_context_coverage_fsm,
	     start    => {gtp_context_coverage_fsm, start_link, []},
	     restart  => temporary,
	     shutdown => 5000,
	     type     => worker,
	     modules  => [gtp_context_coverage_fsm]},
    {ok, {Flags, [Spec]}}.

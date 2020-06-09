%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, new/6, new/7, all/1]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link(?MODULE, []).

new(Sup, Port, Registry, Version, Interface, IfOpts) ->
    Opts = [{hibernate_after, 500},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    new(Sup, Port, Registry, Version, Interface, IfOpts, Opts).

new(Sup, Port, Registry, Version, Interface, IfOpts, Opts) ->
    ?LOG(debug, "new(~p)", [[Sup, Port, Registry, Version, Interface, IfOpts, Opts]]),
    supervisor:start_child(Sup, [Port, Registry, Version, Interface, IfOpts, Opts]).

all(Sup) ->
    supervisor:which_children(Sup).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 5, period => 10},
    Spec = #{id =>       gtp_context,
	     start =>    {gtp_context, start_link, []},
	     restart =>  temporary,
	     shutdown => 1000,
	     type =>     worker,
	     modules =>  [gtp_context]},
    {ok, {Flags, [Spec]}}.

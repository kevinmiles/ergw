%% Copyright 2015, 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path).

-behaviour(gen_statem).

-compile({parse_transform, cut}).
-compile({no_auto_import,[register/2]}).

%% API
-export([start_link/4, all/1,
	 maybe_new_path/3,
	 handle_request/2, handle_response/4,
	 bind/1, bind/2, bind_with_pm/1, unbind/1, down/2,
	 get_handler/2, info/1]).

%% Validate environment Variables
-export([validate_options/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-ifdef(TEST).
-export([ping/3, stop/1]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%% echo_state is the status of the echo send to the remote peer
-record(state, {peer       :: 'UP' | 'DOWN',                    %% State of remote peer
		recovery   :: 'undefined' | non_neg_integer(),
		contexts   :: gb_sets:set(pid()),               %% set of context pids
		echo_ref   :: 'undefined' | ref,
		echo_state :: 'active' | 'stopped' | 'peer_down'}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(GtpPort, Version, RemoteIP, Args) ->
    Opts = [{hibernate_after, 5000},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    gen_statem:start_link(?MODULE, [GtpPort, Version, RemoteIP, Args], Opts).

maybe_new_path(GtpPort, Version, RemoteIP) ->
    maybe_new_path(GtpPort, Version, RemoteIP, false). % Def, No down peer monitoring
        
maybe_new_path(GtpPort, Version, RemoteIP, PDMonF) ->
    case get(GtpPort, Version, RemoteIP) of
	Path when is_pid(Path) ->
	    Path;
	_ ->
	    Args = application:get_env(ergw, path_management, []),
	    ArgsNorm = normalise(Args, []),
	    {ok, Path} = gtp_path_sup:new_path(GtpPort, Version, RemoteIP,
					       [{'pd_mon_f',PDMonF} | ArgsNorm]),
	    Path
    end.

handle_request(#request{gtp_port = GtpPort, ip = IP} = ReqKey, #gtp{version = Version} = Msg) ->
    Path = maybe_new_path(GtpPort, Version, IP),
    gen_statem:cast(Path, {handle_request, ReqKey, Msg}).

handle_response(Path, Request, Ref, Response) ->
    gen_statem:cast(Path, {handle_response, Request, Ref, Response}).

%% bind with path monitoring 
bind_with_pm(#context{remote_restart_counter = RestartCounter} = Context) ->
    path_recovery(RestartCounter, bind_path_with_pm(Context, true)).

bind(#context{remote_restart_counter = RestartCounter} = Context) ->
    path_recovery(RestartCounter, bind_path(Context)).

bind(#gtp{ie = #{{recovery, 0} :=
		     #recovery{restart_counter = RestartCounter}}
	 } = Request, Context) ->
    path_recovery(RestartCounter, bind_path(Request, Context));
bind(#gtp{ie = #{{v2_recovery, 0} :=
		     #v2_recovery{restart_counter = RestartCounter}}
	 } = Request, Context) ->
    path_recovery(RestartCounter, bind_path(Request, Context));
bind(Request, Context) ->
    path_recovery(undefined, bind_path(Request, Context)).

unbind(#context{version = Version, control_port = GtpPort,
		remote_control_teid = #fq_teid{ip = RemoteIP}}) ->
    case get(GtpPort, Version, RemoteIP) of
	Path when is_pid(Path) ->
	    gen_statem:call(Path, {unbind, self()});
	_ ->
	    ok
    end.

down(GtpPort, IP) ->
    down(GtpPort, v1, IP),
    down(GtpPort, v2, IP).

down(GtpPort, Version, IP) ->
    case get(GtpPort, Version, IP) of
	Path when is_pid(Path) ->
	    gen_statem:cast(Path, down);
	_ ->
	    ok
    end.

get(#gtp_port{name = PortName}, Version, IP) ->
    gtp_path_reg:lookup({PortName, Version, IP}).

all(Path) ->
    gen_statem:call(Path, all).

info(Path) ->
    gen_statem:call(Path, info).

get_handler(#gtp_port{type = 'gtp-u'}, _) ->
    gtp_v1_u;
get_handler(#gtp_port{type = 'gtp-c'}, v1) ->
    gtp_v1_c;
get_handler(#gtp_port{type = 'gtp-c'}, v2) ->
    gtp_v2_c.

-ifdef(TEST).
ping(GtpPort, Version, IP) ->
    case get(GtpPort, Version, IP) of
	Path when is_pid(Path) ->
	    gen_statem:cast(Path, '$ping');
	_ ->
	    ok
    end.

stop(Path) ->
    gen_statem:call(Path, '$stop').
-endif.

%%%===================================================================
%%% Options Validation
%%%===================================================================
validate_options(Values) ->
    ergw_config:validate_options(fun validate_option/2, Values, [], list).

%% echo retry interval timeout in Seconds
validate_option(t3, Value) when is_integer(Value) andalso Value > 0 ->
    Value;
%% echo retry Count
validate_option(n3, Value) when is_integer(Value) andalso Value > 0 ->
    Value;
%% echo ping interval (minimum value 60 seconds, 3GPP 23.007, Chap 20)
validate_option(ping, Value) when is_integer(Value) andalso Value >= 60 ->
    Value;
%% peer down echo check if restored interval in seconds (>= 60)
validate_option(pd_mon_t, Value) when is_integer(Value) andalso Value >= 60 -> 
    Value;
%% peer down monitoring duration in seconds (>= 60)
validate_option(pd_mon_dur, Value) when is_integer(Value) andalso Value >= 60 ->
    Value;
validate_option(Par, Value) ->
    throw({error, {options, {Par, Value}}}).

%%%===================================================================
%%% Protocol Module API
%%%===================================================================

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> [handle_event_function, state_enter].

init([#gtp_port{name = PortName} = GtpPort, Version, RemoteIP, Args]) ->
    gtp_path_reg:register({PortName, Version, RemoteIP}),

    State = #state{peer       = 'UP',
		   contexts   = gb_sets:empty(),
		   echo_ref = undefined, 
		   echo_state = stopped},

%% Timer value: echo    = echo interval when peer is up.
%% Timer valUe: pd_echo = echo interval when peer is down (proxy mode)
%% Timer value: pd_dur  = Total duration for which echos are sent to 
%%                        down peer, before the path is cleared (Proxy Mode)
%%                        in case it is removed from the DNS server
    Data = #{
	     %% Path Info Keys
	     gtp_port   => GtpPort, % #gtp_port{}
	     version    => Version, % v1 | v2
	     handler    => get_handler(GtpPort, Version),
	     ip         => RemoteIP,
         %% Peer Down Monitor Flag
	     pd_mon_f => proplists:get_value(pd_mon_f, Args, false), % true | false
	     %% Echo Info values
	     t3         => proplists:get_value(t3, Args, timer:seconds(10)), %% 10sec
	     n3         => proplists:get_value(n3, Args, 5),
	     echo       => proplists:get_value(ping, Args, timer:seconds(60)),
	     pd_echo    => proplists:get_value(pd_mon_t, Args, timer:seconds(300)),
	     pd_dur     => proplists:get_value(pd_mon_dur, Args, timer:seconds(7200))
	},

    ?LOG(debug, "State: ~p Data: ~p", [State, Data]),
    {ok, State, Data}.

<<<<<<< HEAD
<<<<<<< HEAD
=======
>>>>>>> rebased on latest master
handle_event(enter, #state{contexts = OldCtxS}, #state{contexts = CtxS}, Data)
  when OldCtxS =/= CtxS ->
    Actions = update_path_counter(gb_sets:size(CtxS), Data),
    {keep_state_and_data, Actions};
<<<<<<< HEAD
handle_event(enter, #state{echo_timer = OldEchoT}, #state{echo_timer = idle},
	     #{echo := EchoInterval}) when OldEchoT =/= idle ->
=======
handle_event(enter, #state{echo_state = stopped}, #state{echo_state = active},
	     #{echo := EchoInterval}) ->
    {keep_state_and_data, [{{timeout, echo}, EchoInterval, start_echo}]};
handle_event(enter, #state{echo_ref = Ref}, #state{echo_state = active},
	     #{echo := EchoInterval}) when is_reference(Ref) ->
    {keep_state_and_data, [{{timeout, echo}, EchoInterval, start_echo}]};
handle_event(enter, #state{echo_ref = Ref}, #state{echo_state = peer_down},
	     #{pd_echo := EchoInterval}) when is_reference(Ref) ->
>>>>>>> rebased on latest master
    {keep_state_and_data, [{{timeout, echo}, EchoInterval, start_echo}]};
handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

<<<<<<< HEAD
handle_event({timeout, echo}, stop_echo, State, Data) ->
    {next_state, State#state{echo_timer = stopped}, Data, [{{timeout, echo}, cancel}]};

handle_event({timeout, echo}, start_echo, #state{echo_timer = EchoT} = State0, Data)
  when EchoT =:= stopped;
       EchoT =:= idle ->
    State = send_echo_request(State0, Data),
    {next_state, State, Data};
handle_event({timeout, echo}, start_echo, _State, _Data) ->
=======
handle_event(enter, _OldState, _State, _Data) ->
>>>>>>> rebasing on master changes 22-July-2020
    keep_state_and_data;

handle_event({call, From}, all, _State, #{table := TID}) ->
    Reply = ets:tab2list(TID),
=======
%% If monitoring  down_peer, don't stop sending monitor echos 
%% just because there are no sessionss
handle_event({timeout, echo}, stop_echo, #state{echo_state = peer_down} = State0, Data) ->
    State = monitor_down_peer(State0, Data),
    {next_state, State, Data};
handle_event({timeout, echo}, stop_echo, State, Data) ->
    {next_state, State#state{echo_state = stopped}, Data, [{{timeout, echo}, cancel}]};

handle_event({timeout, echo}, start_echo, #state{echo_state = peer_down} = State0, Data) ->
    State = monitor_down_peer(State0, Data),
    {next_state, State#state{echo_state = peer_down}, Data};
handle_event({timeout, echo}, start_echo, 
	     #state{echo_ref = undefined, echo_state = EchoS} = State0, Data) ->
    State = send_echo_request(State0, Data),
    NEchoS = case EchoS of
		 stopped ->
		     active;
		 _ ->
		     EchoS
             end,
    {next_state, State#state{echo_state = NEchoS}, Data};
handle_event({timeout, echo}, start_echo, _State, _Data) ->
    keep_state_and_data;
% Peer down monitoring duration expired, node still down. Terminate PATH! 
% Allocated RemoteIP peer may have been removed by DNS. 
handle_event({timeout, pd_dur}, _, _State,
    #{gtp_port := #gtp_port{name = PortName}, version := Version, ip := RemoteIP}) ->
    gtp_path_reg:remove_down_peer(RemoteIP),
    gtp_path_reg:unregister({PortName, Version, RemoteIP}),
    {keep_state_and_data, [{stop, pd_mon_timeout}]};

handle_event({call, From}, all, #state{contexts = CtxS}, _Data) ->
    Reply = gb_sets:to_list(CtxS),
>>>>>>> rebased on latest master
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {bind, Pid}, #state{recovery = RestartCounter} = State0, Data) ->
    State = register(Pid, State0),
    {next_state, State, Data, [{reply, From, {ok, RestartCounter}}]};

handle_event({call, From}, {bind, Pid, RestartCounter}, State0, Data) ->
    State1 = update_restart_counter(RestartCounter, State0, Data),
    State = register(Pid, State1),
    {next_state, State, Data, [{reply, From, ok}]};

handle_event({call, From}, {unbind, Pid}, State0, Data) ->
    State = unregister(Pid, State0),
    {next_state, State, Data, [{reply, From, ok}]};

handle_event({call, From}, info, #state{contexts = CtxS} = State,
	     #{gtp_port := #gtp_port{name = Name},
	       version := Version, ip := IP}) ->
    Cnt = gb_sets:size(CtxS),
    Reply = #{path => self(), port => Name, tunnels => Cnt,
	      version => Version, ip => IP, state => State},
    {keep_state_and_data, [{reply, From, Reply}]};

%% test support
handle_event({call, From}, '$stop', _State, _Data) ->
    {stop_and_reply, normal, [{reply, From, ok}]};

<<<<<<< HEAD
handle_event({call, From}, Request, _State, Data) ->
    ?LOG(warning, "handle_event(call,...): ~p", [Request]),
    {keep_state_and_data, [{reply, From, ok}]};

%% If an echo request received from down peer i.e state = 'INACTIVE', then
%% cancel peer down duration timer, Peer down echo timer.
%% wait for first GTP Msg to start sending normal echos again. 
handle_event(cast, {handle_request, ReqKey, #gtp{type = echo_request} = Msg0}, 
	     #state{peer = 'INACTIVE'} = State0,
	     #{gtp_port := GtpPort, ip := RemoteIP, handler := Handler} = Data0) ->
    ?LOG(debug, "echo_request from inactive peer: ~p", [Msg0]),
    try gtp_packet:decode_ies(Msg0) of
        Msg = #gtp{} ->
            {State, Data} = handle_recovery_ie(Msg, State0, Data0),

            ResponseIEs = Handler:build_recovery(echo_response, GtpPort, true, []),
            Response = Msg#gtp{type = echo_response, ie = ResponseIEs},
            ergw_gtp_c_socket:send_response(ReqKey, Response, false),
            gtp_path_reg:remove_down_peer(RemoteIP),
            Actions0 = timeout_action([], infinity, 'pd_echo'),
            Actions = timeout_action(Actions0, infinity, 'pd_dur'),
            {next_state, State#state{peer ='DOWN', echo_timer = 'stopped'}, Data, 
             Actions}
    catch
	Class:Error ->
	    ?LOG(error, "GTP decoding failed with ~p:~p for ~p", [Class, Error, Msg0]),
	    {noreply, State0}
    end;
=======
handle_event({call, From}, Request, _State, _Data) ->
    ?LOG(warning, "handle_event(call,...): ~p", [Request]),
    {keep_state_and_data, [{reply, From, ok}]};
>>>>>>> rebased on latest master

%% If an echo request received from down peer i.e echo_state = 'peer_down', then
%% cancel peer down duration timer, Peer down echo timer. Reset
handle_event(cast, {handle_request, ReqKey, #gtp{type = echo_request} = Msg0},
	     #state{echo_state = EchoState} = State0, #{gtp_port := GtpPort, ip := IP, handler := Handler} = Data) ->
    ?LOG(debug, "echo_request: ~p", [Msg0]),
    try gtp_packet:decode_ies(Msg0) of
	Msg = #gtp{} ->
	    State = handle_recovery_ie(Msg, State0, Data),

	    ResponseIEs = Handler:build_recovery(echo_response, GtpPort, true, []),
	    Response = Msg#gtp{type = echo_response, ie = ResponseIEs},
	    ergw_gtp_c_socket:send_response(ReqKey, Response, false),
	    if EchoState =:= peer_down ->
		    gtp_path_reg:remove_down_peer(IP),
		    {next_state, State#state{peer = 'DOWN', echo_state = stopped}, Data,
		     [{{timeout, echo}, cancel}, {{timeout, pd_dur}, cancel}]};
	       true ->
		    {next_state, State, Data}
	    end
    catch
	Class:Error ->
	    ?LOG(error, "GTP decoding failed with ~p:~p for ~p",
		 [Class, Error, Msg0]),
	    keep_state_and_data
    end;

handle_event(cast, down, State, Data) ->
    {next_state, path_down(undefined, State), Data};

handle_event(cast, {handle_response, echo_request, ReqRef, _Msg}, #state{echo_ref = SRef}, _)
  when ReqRef /= SRef ->
    keep_state_and_data;


handle_event(cast, {handle_response, echo_request, _, Msg}, State0, Data) ->
    ?LOG(debug, "echo_response: ~p", [Msg]),
    State1 = handle_recovery_ie(Msg, State0, Data),
    {State, Data, Actions} = echo_response(Msg, State1, Data),
    {next_state, State, Data, Actions};

%% test support start
handle_event(cast, '$ping', #state{echo_ref = Ref}, _Data)
  when is_reference(Ref) ->
    keep_state_and_data;
handle_event(cast, '$ping', #state{echo_state = active} = State0, Data) ->
    State = send_echo_request(State0, Data),
    {next_state, State, Data, [{{timeout, echo}, cancel}]};
handle_event(cast, '$ping', #state{echo_state = peer_down} = State0, Data) ->
    State = monitor_down_peer(State0, Data),
    {next_state, State, Data, [{{timeout, echo}, cancel}]};
handle_event(cast, '$ping', #state{echo_state = stopped} = State0, Data) ->
    State = send_echo_request(State0, Data),
    {next_state, State, Data, [{{timeout, echo}, cancel}]};
%% test support end

handle_event(cast, Msg, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(cast, ...): ~p", [self(), ?MODULE, Msg]),
    keep_state_and_data;

handle_event(info,{'DOWN', _MonitorRef, process, Pid, _Info}, State0, Data) ->
    State = unregister(Pid, State0),
    {next_state, State, Data};

handle_event({timeout, 'echo'}, _, #state{echo_state = active} = State0, Data) ->
    ?LOG(debug, "handle_event timeout: ~p", [Data]),
    State = send_echo_request(State0, Data),
    {next_state, State, Data};
handle_event({timeout, 'echo'}, _, #state{echo_state = down_peer} = State0, Data) ->
    ?LOG(debug, "handle_event timeout when Peer down: ~p", [Data]),
    State = monitor_down_peer(State0, Data),
    {next_state, State, Data};


handle_event({timeout, 'echo'}, _, _State, _Data) ->
    ?LOG(debug, "handle_event timeout: ~p", [_Data]),
    keep_state_and_data;

handle_event(info, Info, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(info, ...): ~p", [self(), ?MODULE, Info]),
    keep_state_and_data.

% Monitoring down peer for too long, kill path process
terminate(pd_mon_timeout, State, _data) ->
    ?LOG(error, "terminate Path, peer down for too long: State ~p", [State]),
    ok;

terminate(_Reason, _State, _Data) ->
    %% TODO: kill all PDP Context on this path
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% 3GPP TS 23.007, Sect. 18 GTP-C-based restart procedures:
%%
%% The GTP-C entity that receives a Recovery Information Element in an Echo Response
%% or in another GTP-C message from a peer, shall compare the received remote Restart
%% counter value with the previous Restart counter value stored for that peer entity.
%%
%%   - If no previous value was stored the Restart counter value received in the Echo
%%     Response or in the GTP-C message shall be stored for the peer.
%%
%%   - If the value of a Restart counter previously stored for a peer is smaller than
%%     the Restart counter value received in the Echo Response message or the GTP-C
%%     message, taking the integer roll-over into account, this indicates that the
%%     entity that sent the Echo Response or the GTP-C message has restarted. The
%%     received, new Restart counter value shall be stored by the receiving entity,
%%     replacing the value previously stored for the peer.
%%
%%   - If the value of a Restart counter previously stored for a peer is larger than
%%     the Restart counter value received in the Echo Response message or the GTP-C message,
%%     taking the integer roll-over into account, this indicates a possible race condition
%%     (newer message arriving before the older one). The received new Restart counter value
%%     shall be discarded and an error may be logged

-define(SMALLER(S1, S2), ((S1 < S2 andalso (S2 - S1) < 128) orelse (S1 > S2 andalso (S1 - S2) > 128))).

update_restart_counter(Counter, #state{recovery = undefined} = State, _Data) ->
    State#state{recovery = Counter};
update_restart_counter(Counter, #state{recovery = Counter} = State, _Data) ->
    State;
update_restart_counter(New, #state{recovery = Old} = State, #{ip := IP})
  when ?SMALLER(Old, New) ->
    ?LOG(warning, "GSN ~s restarted (~w != ~w)",
     [inet:ntoa(IP), Old, New]),
    path_down(New, State);
update_restart_counter(New, #state{recovery = Old} = State, #{ip := IP})
  when not ?SMALLER(Old, New) ->
    ?LOG(warning, "possible race on message with restart counter for GSN ~s (old: ~w, new: ~w)",
	 [inet:ntoa(IP), Old, New]),
    State.

handle_recovery_ie(#gtp{version = v1,
			ie = #{{recovery, 0} :=
				   #recovery{restart_counter =
						 RestartCounter}}}, State, Data) ->
    update_restart_counter(RestartCounter, State, Data);

handle_recovery_ie(#gtp{version = v2,
			ie = #{{v2_recovery, 0} :=
				   #v2_recovery{restart_counter =
						    RestartCounter}}}, State, Data) ->
    update_restart_counter(RestartCounter, State, Data);
handle_recovery_ie(_Msg, State, _Data) ->
    State.

foreach_context(none, _Fun) ->
    ok;
foreach_context({Pid, Iter}, Fun) ->
    Fun(Pid),
    foreach_context(gb_sets:next(Iter), Fun).

register(Pid, #state{contexts = CtxS} = State) ->
    ?LOG(debug, "~s: register(~p)", [?MODULE, Pid]),
    erlang:monitor(process, Pid),
    State#state{contexts = gb_sets:add_element(Pid, CtxS)}.

unregister(Pid, #state{contexts = CtxS} = State) ->
    State#state{contexts = gb_sets:del_element(Pid, CtxS)}.

update_path_counter(PathCounter, #{gtp_port := GtpPort, version := Version, ip := IP}) ->
    ergw_prometheus:gtp_path_contexts(GtpPort, IP, Version, PathCounter),
    if PathCounter =:= 0 ->
	    [{{timeout, echo}, 0, stop_echo}];
       true ->
	    [{{timeout, echo}, 0, start_echo}]
    end.

bind_path(#gtp{version = Version}, Context) ->
    bind_path(Context#context{version = Version}).

bind_path(#context{version = Version, control_port = CntlGtpPort,
		   remote_control_teid = #fq_teid{ip = RemoteCntlIP}} = Context) ->
    Path = maybe_new_path(CntlGtpPort, Version, RemoteCntlIP),
    Context#context{path = Path}.

bind_path_with_pm(#context{version = Version, control_port = CntlGtpPort,
			   remote_control_teid = #fq_teid{ip = RemoteCntlIP}} = Context,
		  PeerDownMonF) ->
    Path = maybe_new_path(CntlGtpPort, Version, RemoteCntlIP, PeerDownMonF),
    Context#context{path = Path}.

path_recovery(RestartCounter, #context{path = Path} = Context)
  when is_integer(RestartCounter) ->
    ok = gen_statem:call(Path, {bind, self(), RestartCounter}),
    Context#context{remote_restart_counter = RestartCounter};
path_recovery(_RestartCounter, #context{path = Path} = Context) ->
    {ok, PathRestartCounter} = gen_statem:call(Path, {bind, self()}),
    Context#context{remote_restart_counter = PathRestartCounter}.

monitor_down_peer(State, #{gtp_port := GtpPort, handler := Handler, ip := DstIP,
            t3 := T3}) ->
    send_echo_request_1(State, GtpPort, Handler, DstIP, T3, 1).

send_echo_request(State, #{gtp_port := GtpPort, handler := Handler, ip := DstIP,
		    t3 := T3, n3 := N3}) ->
    send_echo_request_1(State, GtpPort, Handler, DstIP, T3, N3).

send_echo_request_1(State, GtpPort, Handler, DstIP, T3, N3) ->
    Msg = Handler:build_echo_request(GtpPort),
    Ref = erlang:make_ref(),
    CbInfo = {?MODULE, handle_response, [self(), echo_request, Ref]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, ?GTP1c_PORT, T3, N3, Msg, CbInfo),
    State#state{echo_ref = Ref}.

echo_response(Msg, State, Data) ->
    update_path_state(Msg, State#state{echo_ref = 'undefined'}, Data).

%% Down peer has come up, remove down IP and reset
update_path_state(#gtp{}, #state{echo_state = peer_down} = State, #{ip := IP} = Data) ->
    gtp_path_reg:remove_down_peer(IP),
    {State#state{peer = 'UP', echo_state = stopped}, Data,
     [{{timeout, pd_dur}, cancel}]};
update_path_state(#gtp{}, State, Data) ->
    {State#state{peer = 'UP'}, Data, []};
% Do nothing when path in state 'peer_down', start timer to trigger next echo in state enter
%% invalid mesage or time out received.
update_path_state(_, #state{echo_state = peer_down} = State, Data) ->
    {State, Data, []};
%Path is to be monitored, for a pd_dur duration
update_path_state(_, State0,
		  #{pd_mon_f := true, pd_dur := PDDurInterval, ip := IP} = Data) ->
    State = path_down(undefined, State0#state{peer = 'DOWN', echo_state = peer_down}),
    gtp_path_reg:add_down_peer(IP),
    {State, Data, [{{timeout, pd_dur}, PDDurInterval, pd_dur}]};
update_path_state(_, State0, Data) ->
    State = path_down(undefined, State0#state{peer = 'DOWN'}),
    {State, Data, []}.

path_down(RestartCounter, #state{contexts = CtxS} = State) ->
    Path = self(),
    proc_lib:spawn(
      fun() ->
	      foreach_context(gb_sets:next(gb_sets:iterator(CtxS)),
			      gtp_context:path_restart(_, Path))
      end),
    State#state{
      recovery = RestartCounter,
      contexts = gb_sets:empty()
     }.
% normalise values to milliseconds
normalise([], NewArgs) ->
    NewArgs;
normalise([{n3, Val} | Rest], NewArgs) ->
    normalise(Rest, [{n3, Val} | NewArgs]);
normalise([{Par, Val} | Rest], NewArgs) ->
    normalise(Rest, [{Par, timer:seconds(Val)} | NewArgs]).

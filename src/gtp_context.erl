%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context).

-behavior(gen_statem).
-behavior(ergw_context).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([handle_response/4,
	 start_link/2, start_link/4, start_link/5,
	 send_request/7,
	 send_response/2, send_response/3,
	 send_request/6, resend_request/2,
	 request_finished/1,
	 path_restart/2,
	 terminate_colliding_context/1, terminate_context/1,
	 delete_context/1, trigger_delete_context/1,
	 remote_context_register/1, remote_context_register_new/1, remote_context_update/2,
	 enforce_restrictions/2,
	 info/1,
	 validate_options/3,
	 validate_option/2,
	 generic_error/3,
	 port_key/2, port_teid_key/2]).
-export([usage_report_to_accounting/1,
	 collect_charging_events/3]).
-export([keep_state_idle/2, keep_state_idle/3,
	 keep_state_busy/3,
	 next_state_idle/2, next_state_idle/3,
	 next_state_terminating/2,
	 next_state_shutdown/2, next_state_shutdown/3]).

%% ergw_context callbacks
-export([sx_report/2, pfcp_timer/3, port_message/2, port_message/4]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-ifdef(TEST).
-export([test_cmd/2]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-define(TestCmdTag, '$TestCmd').

-import(ergw_aaa_session, [to_session/1]).

-define(IDLE_TIMEOUT, 100).
-define(IDLE_INIT_TIMEOUT, 5000).

-define('Tunnel Endpoint Identifier Data I',	{tunnel_endpoint_identifier_data_i, 0}).

%%====================================================================
%% API
%%====================================================================

handle_response(Context, ReqInfo, Request, Response) ->
    gen_statem:cast(Context, {handle_response, ReqInfo, Request, Response}).

%% send_request/7
send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, CbInfo).

%% send_request/6
send_request(GtpPort, DstIP, DstPort, ReqId, Msg, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, DstPort, ReqId, Msg, CbInfo).

resend_request(GtpPort, ReqId) ->
    ergw_gtp_c_socket:resend_request(GtpPort, ReqId).

start_link(RecordId, Opts) ->
    gen_statem:start_link(?MODULE, [RecordId], Opts).

start_link(GtpPort, Version, Interface, IfOpts, Opts) ->
    gen_statem:start_link(?MODULE, [GtpPort, Version, Interface, IfOpts], Opts).

start_link(RecordId, State, Data, Opts) ->
    gen_statem:start_link(?MODULE, [RecordId, State, Data], Opts).

path_restart(Context, Path) ->
    jobs:run(path_restart, fun() -> gen_statem:call(Context, {path_restart, Path}) end).

remote_context_register(Context)
  when is_record(Context, context) ->
    Keys = context2keys(Context),
    gtp_context_reg:register(Keys, ?MODULE, self()).

remote_context_register_new(Context)
  when is_record(Context, context) ->
    Keys = context2keys(Context),
    case gtp_context_reg:register_new(Keys, ?MODULE, self()) of
	ok ->
	    ok;
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Context))
    end.

remote_context_update(OldContext, NewContext)
  when is_record(OldContext, context),
       is_record(NewContext, context) ->
    OldKeys = context2keys(OldContext),
    NewKeys = context2keys(NewContext),
    Delete = ordsets:subtract(OldKeys, NewKeys),
    Insert = ordsets:subtract(NewKeys, OldKeys),
    gtp_context_reg:update(Delete, Insert, ?MODULE, self()).

delete_context(Context) ->
    gen_statem:call(Context, delete_context).

trigger_delete_context(Context) ->
    gen_statem:cast(Context, delete_context).

%% TODO: add online charing events
collect_charging_events(OldS, NewS, _Context) ->
    EvChecks =
	[
	 {'CGI',                     'cgi-sai-change'},
	 {'SAI',                     'cgi-sai-change'},
	 {'ECGI',                    'ecgi-change'},
	 %%{qos, 'max-cond-change'},
	 {'3GPP-MS-TimeZone',        'ms-time-zone-change'},
	 {'QoS-Information',         'qos-change'},
	 {'RAI',                     'rai-change'},
	 {'3GPP-RAT-Type',           'rat-change'},
	 {'3GPP-SGSN-Address',       'sgsn-sgw-change'},
	 {'3GPP-SGSN-IPv6-Address',  'sgsn-sgw-change'},
	 {'3GPP-SGSN-MCC-MNC',       'sgsn-sgw-plmn-id-change'},
	 {'TAI',                     'tai-change'},
	 %%{ qos, 'tariff-switch-change'},
	 {'3GPP-User-Location-Info', 'user-location-info-change'}
	],

    Events =
	lists:foldl(
	  fun({Field, Ev}, Evs) ->
		  Old = maps:get(Field, OldS, undefined),
		  New = maps:get(Field, NewS, undefined),
		  if Old /= New ->
			  [Ev | Evs];
		     true ->
			  Evs
		  end
	  end, [], EvChecks),
    case ergw_charging:is_charging_event(offline, Events) of
	false ->
	    [];
	ChargeEv ->
	    [{offline, {ChargeEv, OldS}}]
    end.

%% 3GPP TS 29.060 (GTPv1-C) and TS 29.274 (GTPv2-C) have language that states
%% that when an incomming Create PDP Context/Create Session requests collides
%% with an existing context based on a IMSI, Bearer, Protocol tuple, that the
%% preexisting context should be deleted locally. This function does that.
terminate_colliding_context(#context{control_port = GtpPort, context_id = Id})
  when Id /= undefined ->
    case gtp_context_reg:lookup(port_key(GtpPort, Id)) of
	{?MODULE, Server} when is_pid(Server) ->
	    gtp_context:terminate_context(Server);
	_ ->
	    ok
    end;
terminate_colliding_context(_) ->
    ok.

terminate_context(Context)
  when is_pid(Context) ->
    try
	gen_statem:call(Context, terminate_context)
    catch
	exit:_ ->
	    ok
    end,
    gtp_context_reg:await_unreg(Context).

info(Context) ->
    gen_statem:call(Context, info).

-ifdef(TEST).

test_cmd(Pid, Cmd) when is_pid(Pid) ->
    gen_statem:call(Pid, {?TestCmdTag, Cmd}).

-endif.

enforce_restrictions(Msg, #context{restrictions = Restrictions} = Context) ->
    lists:foreach(fun(R) -> enforce_restriction(Context, Msg, R) end, Restrictions).

next_state_terminating(State, Data) ->
    Actions = [{state_timeout, 5000, stop}],
    {next_state, State#c_state{session = terminating, fsm = busy}, Data, Actions}.

next_state_shutdown(State, Data) ->
    next_state_shutdown(State, Data, []).

next_state_shutdown(State, Data, Actions) ->
    % TODO unregiter context ....

    %% this makes stop the last message in the inbox and
    %% guarantees that we process any left over messages first
    gen_statem:cast(self(), stop),
    {next_state, State#c_state{session = shutdown, fsm = busy}, Data, Actions}.

keep_state_idle(State, Data) ->
    keep_state_idle(State, Data, []).

%% keep_state_idle(#c_state{session = up} = State, Data, Actions) ->
%%     {next_state, State#c_state{fsm = idle}, Data, Actions};
keep_state_idle(_State, Data, Actions) ->
    {keep_state, Data, Actions}.

next_state_idle(State, Data) ->
    next_state_idle(State, Data, []).

next_state_idle(#c_state{session = up} = State, Data, Actions) ->
    {next_state, State#c_state{fsm = idle}, Data, Actions};
next_state_idle(State, Data, Actions) ->
    {next_state, State, Data, Actions}.

keep_state_busy(#c_state{session = up} = State, Data, Actions) ->
    {next_state, State#c_state{fsm = busy}, Data, Actions};
keep_state_busy(_State, Data, Actions) ->
    {keep_state, Data, Actions}.


%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

-define(ContextDefaults, [{node_selection, undefined},
			  {aaa,            []}]).

-define(DefaultAAAOpts,
	#{
	  'AAA-Application-Id' => ergw_aaa_provider,
	  'Username' => #{default => <<"ergw">>,
			  from_protocol_opts => true},
	  'Password' => #{default => <<"ergw">>}
	 }).

validate_options(Fun, Opts, Defaults) ->
    ergw_config:validate_options(Fun, Opts, Defaults ++ ?ContextDefaults, map).

validate_option(protocol, Value)
  when Value == 'gn' orelse
       Value == 's5s8' orelse
       Value == 's11' ->
    Value;
validate_option(handler, Value) when is_atom(Value) ->
    Value;
validate_option(sockets, Value) when is_list(Value) ->
    Value;
validate_option(node_selection, [S|_] = Value)
  when is_atom(S) ->
    Value;
validate_option(aaa, Value) when is_list(Value); is_map(Value) ->
    ergw_config:opts_fold(fun validate_aaa_option/3, ?DefaultAAAOpts, Value);
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_aaa_option(Key, AppId, AAA)
  when Key == appid; Key == 'AAA-Application-Id' ->
    AAA#{'AAA-Application-Id' => AppId};
validate_aaa_option(Key, Value, AAA)
  when (is_list(Value) orelse is_map(Value)) andalso
       (Key == 'Username' orelse Key == 'Password') ->
    %% Attr = maps:get(Key, AAA),
    %% maps:put(Key, ergw_config:opts_fold(validate_aaa_attr_option(Key, _, _, _), Attr, Value), AAA);

    %% maps:update_with(Key, fun(Attr) ->
    %% 				  ergw_config:opts_fold(validate_aaa_attr_option(Key, _, _, _), Attr, Value)
    %% 			  end, AAA);
    maps:update_with(Key, ergw_config:opts_fold(validate_aaa_attr_option(Key, _, _, _), _, Value), AAA);

validate_aaa_option(Key, Value, AAA)
  when Key == '3GPP-GGSN-MCC-MNC' ->
    AAA#{'3GPP-GGSN-MCC-MNC' => Value};
validate_aaa_option(Key, Value, _AAA) ->
    throw({error, {options, {aaa, {Key, Value}}}}).

validate_aaa_attr_option('Username', default, Default, Attr) ->
    Attr#{default => Default};
validate_aaa_attr_option('Username', from_protocol_opts, Bool, Attr)
  when Bool == true; Bool == false ->
    Attr#{from_protocol_opts => Bool};
validate_aaa_attr_option('Password', default, Default, Attr) ->
    Attr#{default => Default};
validate_aaa_attr_option(Key, Setting, Value, _Attr) ->
    throw({error, {options, {aaa_attr, {Key, Setting, Value}}}}).

%%====================================================================
%% ergw_context API
%%====================================================================

sx_report(RecordIdOrPid, Report) ->
    context_run(RecordIdOrPid, call, {sx, Report}).

pfcp_timer(RecordIdOrPid, Time, Evs) ->
    context_run(RecordIdOrPid, call, {pfcp_timer, Time, Evs}).

%% TEID handling for GTPv1 is brain dead....
port_message(Request, #gtp{version = v2, type = MsgType, tei = 0} = Msg)
  when MsgType == change_notification_request;
       MsgType == change_notification_response ->
    Keys = gtp_v2_c:get_msg_keys(Msg),
    ergw_context:port_message(Keys, Request, Msg);

%% same as above for GTPv2
port_message(Request, #gtp{version = v1, type = MsgType, tei = 0} = Msg)
  when MsgType == ms_info_change_notification_request;
       MsgType == ms_info_change_notification_response ->
    Keys = gtp_v1_c:get_msg_keys(Msg),
    ergw_context:port_message(Keys, Request, Msg);

port_message(#request{gtp_port = GtpPort} = Request,
		 #gtp{version = Version, tei = 0} = Msg) ->
    case get_handler_if(GtpPort, Msg) of
	{ok, Interface, InterfaceOpts} ->
	    case ergw:get_accept_new() of
		true -> ok;
		_ ->
		    throw({error, no_resources_available})
	    end,
	    validate_teid(Msg),
	    Server = context_new(GtpPort, Version, Interface, InterfaceOpts),
	    handle_port_message(Server, Request, Msg, false);

	{error, _} = Error ->
	    throw(Error)
    end;
port_message(_Request, _Msg) ->
    throw({error, not_found}).

handle_port_message(Server, Request, Msg, Resent) when is_pid(Server) ->
    if not Resent -> register_request(?MODULE, Server, Request);
       true       -> ok
    end,
    gen_statem:call(Server, {handle_message, Request, Msg, Resent}).

%% port_message/4
port_message(RecordIdOrPid, Request, #gtp{type = g_pdu} = Msg, _Resent) ->
    context_run(RecordIdOrPid, cast, {handle_pdu, Request, Msg});
port_message(RecordIdOrPid, Request, Msg, Resent) ->
    EvFun = fun(Server, _) -> handle_port_message(Server, Request, Msg, Resent) end,
    context_run(RecordIdOrPid, EvFun, undefined).

%%====================================================================
%% gen_statem API
%%====================================================================

callback_mode() -> [handle_event_function, state_enter].

init([RecordId]) ->
    process_flag(trap_exit, true),

    case gtp_context_reg:register_name(RecordId, self()) of
	yes ->
	    case ergw_context:get_context_record(RecordId) of
		{ok, State, Data0} ->
		    Data = restore_session_state(Data0),
		    {ok, #c_state{session = State, fsm = init}, Data};
		Other ->
		    {stop, Other}
	    end;
	no ->
	    Pid = gtp_context_reg:whereis_name(RecordId),
	    {stop, {error, {already_started, Pid}}}
    end;

init([CntlPort, Version, Interface,
      #{node_selection := NodeSelect,
	aaa := AAAOpts} = Opts]) ->

    ?LOG(debug, "init(~p)", [[CntlPort, Interface]]),
    process_flag(trap_exit, true),

    {ok, CntlTEI} = ergw_tei_mngr:alloc_tei(CntlPort),

    Id = ergw_gtp_c_socket:get_uniq_id(CntlPort),
    RecordId = iolist_to_binary(["GTP-", integer_to_list(Id)]),

    gtp_context_reg:register_name(RecordId, self()),

    Context = #context{
		 charging_identifier = Id,

		 version           = Version,
		 control_interface = Interface,
		 control_port      = CntlPort,
		 local_control_tei = CntlTEI
		},

    Data = #{
      record_id      => RecordId,
      context        => Context,
      version        => Version,
      interface      => Interface,
      node_selection => NodeSelect,
      aaa_opts       => AAAOpts},

    case init_it(Interface, Opts, Data) of
	{ok, {ok, #c_state{session = SState} = State, FinalData}} ->
	    Meta = get_record_meta(Data),
	    ergw_context:create_context_record(SState, Meta, FinalData),
	    {ok, State, FinalData};
	InitR ->
	    gtp_context_reg:unregister_name(RecordId),
	    case InitR of
		{ok, {stop, _} = R} ->
		    R;
		{ok, ignore} ->
		    ignore;
		{ok, Else} ->
		    exit({bad_return_value, Else});
		{'EXIT', Class, Reason, Stacktrace} ->
		    erlang:raise(Class, Reason, Stacktrace)
	    end
    end.

init_it(Mod, Opts, Data) ->
    try
	{ok, Mod:init(Opts, Data)}
    catch
	throw:R -> {ok, R};
	Class:R:S -> {'EXIT', Class, R, S}
    end.

handle_event({call, From}, info, _, Data) ->
    {keep_state_and_data, [{reply, From, Data}]};

handle_event({call, From}, {?TestCmdTag, pfcp_ctx}, _State, #{pfcp := PCtx}) ->
    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};
handle_event({call, From}, {?TestCmdTag, session}, _State, #{'Session' := Session}) ->
    {keep_state_and_data, [{reply, From, {ok, Session}}]};
handle_event({call, From}, {?TestCmdTag, pcc_rules}, _State, #{pcc := PCC}) ->
    {keep_state_and_data, [{reply, From, {ok, PCC#pcc_ctx.rules}}]};

handle_event(state_timeout, idle, #c_state{fsm = init}, Data) ->
    {stop, normal, Data};
handle_event(state_timeout, idle, #c_state{session = SState, fsm = idle}, Data0) ->
    Data = save_session_state(Data0),
    Meta = get_record_meta(Data),
    ergw_context:put_context_record(SState, Meta, Data),
    {stop, normal, Data};

handle_event(state_timeout, stop, #c_state{session = terminating} = State, Data) ->
    next_state_shutdown(State, Data);
handle_event(cast, stop, #c_state{session = shutdown}, _Data) ->
    {stop, normal};

handle_event(enter, _OldState, #c_state{fsm = init}, _Data) ->
    {keep_state_and_data, [{state_timeout, ?IDLE_INIT_TIMEOUT, idle}]};
handle_event(enter, _OldState, #c_state{fsm = idle}, _Data) ->
    {keep_state_and_data, [{state_timeout, ?IDLE_TIMEOUT, idle}]};

handle_event(enter, OldState, State, #{interface := Interface} = Data) ->
    Interface:handle_event(enter, OldState, State, Data);

handle_event({call, From}, {sx, Report}, State,
	    #{interface := Interface, pfcp := PCtx} = Data0) ->
    ?LOG(debug, "~w: handle_call Sx: ~p", [?MODULE, Report]),
    case Interface:handle_sx_report(Report, State, Data0) of
	{ok, Data} ->
	    keep_state_idle(State, Data, [{reply, From, {ok, PCtx}}]);
	{reply, Reply, Data} ->
	    keep_state_idle(State, Data, [{reply, From, {ok, PCtx, Reply}}]);
	{shutdown, Data} ->
	    next_state_shutdown(State, Data, [{reply, From, {ok, PCtx}}]);
	{error, Reply, Data} ->
	    keep_state_idle(State, Data, [{reply, From, {ok, PCtx, Reply}}]);
	{noreply, Data} ->
	    keep_state_idle(State, Data)
    end;

handle_event({call, From}, {handle_message, Request, #gtp{} = Msg0, Resent}, State, Data) ->
    gen_statem:reply(From, ok),
    Msg = gtp_packet:decode_ies(Msg0),
    ?LOG(debug, "handle gtp request: ~w, ~p",
		[Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),
    handle_request(Request, Msg, Resent, State, Data);

handle_event(cast, {handle_pdu, Request, Msg}, State, #{interface := Interface} = Data) ->
    ?LOG(debug, "handle GTP-U PDU: ~w, ~p",
		[Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),
    Interface:handle_pdu(Request, Msg, State, Data);

handle_event(cast, {handle_response, ReqInfo, Request, Response0}, State,
	    #{interface := Interface} = Data) ->
    try
	Response = gtp_packet:decode_ies(Response0),
	case Response of
	    #gtp{} ->
		?LOG(debug, "handle gtp response: ~p", [gtp_c_lib:fmt_gtp(Response)]),
		validate_message(Response, Data);
	    _ when is_atom(Response) ->
		?LOG(debug, "handle gtp response: ~p", [Response]),
		ok
	end,
	Interface:handle_response(ReqInfo, Response, Request, State, Data)
    catch
	throw:#ctx_err{} = CtxErr ->
	    handle_ctx_error(CtxErr, State, Data);

	Class:Reason:Stacktrace ->
	    ?LOG(error, "GTP response failed with: ~p:~p (~p)", [Class, Reason, Stacktrace]),
	    erlang:raise(Class, Reason, Stacktrace)
    end;

handle_event(info, {update_session, Session, Events}, _State, _Data) ->
    ?LOG(debug, "SessionEvents: ~p~n       Events: ~p", [Session, Events]),
    Actions = [{next_event, internal, {session, Ev, Session}} || Ev <- Events],
    {keep_state_and_data, Actions};

handle_event({call, From}, {pfcp_timer, Time, Evs} = Info, State,
	    #{interface := Interface, pfcp := PCtx0} = Data) ->
    ?LOG(debug, "handle_event ~p:~p", [Interface, Info]),
    gen_statem:reply(From, ok),
    PCtx = ergw_pfcp:timer_expired(Time, PCtx0),
    CtxEvs = ergw_gsn_lib:pfcp_to_context_event(Evs),
    Interface:handle_event(info, {pfcp_timer, CtxEvs}, State, Data#{pfcp => PCtx});

handle_event(info, {timeout, TRef, pfcp_timer} = Info, State,
	    #{interface := Interface, pfcp := PCtx0} = Data) ->
    ?LOG(debug, "handle_info ~p:~p", [Interface,Info]),
    {Evs, PCtx} = ergw_pfcp:timer_expired(TRef, PCtx0),
    CtxEvs = ergw_gsn_lib:pfcp_to_context_event(Evs),
    Interface:handle_event(info, {pfcp_timer, CtxEvs}, State, Data#{pfcp => PCtx});

handle_event(Type, Content, State, #{interface := Interface} = Data) ->
    ?LOG(debug, "~w: handle_event: (~p, ~p, ~p)",
		[?MODULE, Type, Content, State]),
    Interface:handle_event(Type, Content, State, Data).

terminate(Reason, State, #{interface := Interface} = Data) ->
    try
	Interface:terminate(Reason, State, Data)
    after
	terminate_cleanup(State, Data)
    end;
terminate(_Reason, State, Data) ->
    terminate_cleanup(State, Data),
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Message Handling functions
%%%===================================================================

log_ctx_error(#ctx_err{level = Level, where = {File, Line}, reply = Reply}) ->
    ?LOG(debug, "CtxErr: ~w, at ~s:~w, ~p", [Level, File, Line, Reply]).

handle_ctx_error(#ctx_err{level = Level, context = Context} = CtxErr,
		 #c_state{session = State}, Data0) ->
    log_ctx_error(CtxErr),
    Data = if is_record(Context, context) ->
		   Data0#{context => Context};
	      true ->
		   Data0
	   end,
    if Level =:= ?FATAL orelse State =:= init ->
	    {stop, normal, Data};
       true ->
	    {keep_state, Data}
    end.

handle_ctx_error(#ctx_err{reply = Reply} = CtxErr, Handler,
		 Request, #gtp{type = MsgType, seq_no = SeqNo}, State, Data) ->
    Response = if is_list(Reply) orelse is_atom(Reply) ->
		       Handler:build_response({MsgType, Reply});
		  true ->
		       Handler:build_response(Reply)
	       end,
    send_response(Request, Response#gtp{seq_no = SeqNo}),
    handle_ctx_error(CtxErr, State, Data).

handle_request(#request{gtp_port = GtpPort} = Request,
	       #gtp{version = Version} = Msg,
	       Resent, State, #{interface := Interface} = Data0) ->
    ?LOG(debug, "GTP~s ~s:~w: ~p",
		[Version, inet:ntoa(Request#request.ip), Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),

    try
	validate_message(Msg, Data0),
	Interface:handle_request(Request, Msg, Resent, State, Data0)
    catch
	throw:#ctx_err{} = CtxErr ->
	    Handler = gtp_path:get_handler(GtpPort, Version),
	    handle_ctx_error(CtxErr, Handler, Request, Msg, State, Data0);

	Class:Reason:Stacktrace ->
	    ?LOG(error, "GTP~p failed with: ~p:~p (~p)", [Version, Class, Reason, Stacktrace]),
	    erlang:raise(Class, Reason, Stacktrace)
    end.

%% send_response/3
send_response(#request{gtp_port = GtpPort, version = Version} = ReqKey,
	      #gtp{seq_no = SeqNo}, Reply) ->
    Handler = gtp_path:get_handler(GtpPort, Version),
    Response = Handler:build_response(Reply),
    send_response(ReqKey, Response#gtp{seq_no = SeqNo}).

%% send_response/2
send_response(Request, #gtp{seq_no = SeqNo} = Msg) ->
    %% TODO: handle encode errors
    try
	request_finished(Request),
	ergw_gtp_c_socket:send_response(Request, Msg, SeqNo /= 0)
    catch
	Class:Error:Stack ->
	    ?LOG(error, "gtp send failed with ~p:~p (~p) for ~p",
			[Class, Error, Stack, gtp_c_lib:fmt_gtp(Msg)])
    end.

request_finished(Request) ->
    unregister_request(Request).

generic_error(_Request, #gtp{type = g_pdu}, _Error) ->
    ok;
generic_error(#request{gtp_port = GtpPort} = Request,
	      #gtp{version = Version, type = MsgType, seq_no = SeqNo}, Error) ->
    Handler = gtp_path:get_handler(GtpPort, Version),
    Reply = Handler:build_response({MsgType, 0, Error}),
    ergw_gtp_c_socket:send_response(Request, Reply#gtp{seq_no = SeqNo}, SeqNo /= 0).

%%%===================================================================
%%% Internal functions
%%%===================================================================

terminate_cleanup(#c_state{session = State}, Data) when State =/= up ->
    ergw_context:delete_context_record(Data);
terminate_cleanup(_State, _) ->
    ok.

register_request(Handler, Server, #request{key = ReqKey, gtp_port = GtpPort}) ->
    gtp_context_reg:register([port_key(GtpPort, ReqKey)], Handler, Server).

unregister_request(#request{key = ReqKey, gtp_port = GtpPort}) ->
    gtp_context_reg:unregister([port_key(GtpPort, ReqKey)], ?MODULE, self()).

enforce_restriction(Context, #gtp{version = Version}, {Version, false}) ->
    throw(?CTX_ERR(?FATAL, {version_not_supported, []}, Context));
enforce_restriction(_Context, _Msg, _Restriction) ->
    ok.

get_handler_if(GtpPort, #gtp{version = v1} = Msg) ->
    gtp_v1_c:get_handler(GtpPort, Msg);
get_handler_if(GtpPort, #gtp{version = v2} = Msg) ->
    gtp_v2_c:get_handler(GtpPort, Msg).

context_new(GtpPort, Version, Interface, InterfaceOpts) ->
    case gtp_context_sup:new(GtpPort, Version, Interface, InterfaceOpts) of
	{ok, Server} when is_pid(Server) ->
	    Server;
	{error, Error} ->
	    throw({error, Error})
    end.

context_run(Pid, EventType, EventContent) when is_pid(Pid) ->
    context_run_do(Pid, EventType, EventContent);
context_run(RecordId, EventType, EventContent) when is_binary(RecordId) ->
    case gtp_context_reg:whereis_name(RecordId) of
	Pid when is_pid(Pid) ->
	    context_run_do(Pid, EventType, EventContent);
	_ ->
	    case gtp_context_sup:run(RecordId) of
		{ok, Pid2} ->
		    context_run_do(Pid2, EventType, EventContent);
		{already_started, Pid3} ->
		    context_run_do(Pid3, EventType, EventContent);
		Other ->
		    Other
	    end
    end.

context_run_do(Server, cast, EventContent) ->
    gen_statem:cast(Server, EventContent);
context_run_do(Server, call, EventContent) ->
    gen_statem:call(Server, EventContent);
context_run_do(Server, info, EventContent) ->
    Server ! EventContent;
context_run_do(Server, Fun, EventContent) when is_function(Fun) ->
    Fun(Server, EventContent).

validate_teid(#gtp{version = v1, type = MsgType, tei = TEID}) ->
    gtp_v1_c:validate_teid(MsgType, TEID);
validate_teid(#gtp{version = v2, type = MsgType, tei = TEID}) ->
    gtp_v2_c:validate_teid(MsgType, TEID).

validate_message(#gtp{version = Version, ie = IEs} = Msg, Data) ->
    Cause = case Version of
		v1 -> gtp_v1_c:get_cause(IEs);
		v2 -> gtp_v2_c:get_cause(IEs)
	    end,
    case validate_ies(Msg, Cause, Data) of
	[] ->
	    ok;
	Missing ->
	    ?LOG(debug, "Missing IEs: ~p", [Missing]),
	    ?LOG(error, "Missing IEs: ~p", [Missing]),
	    throw(?CTX_ERR(?WARNING, [{mandatory_ie_missing, hd(Missing)}]))
    end.

validate_ies(#gtp{version = Version, type = MsgType, ie = IEs}, Cause, #{interface := Interface}) ->
    Spec = Interface:request_spec(Version, MsgType, Cause),
    lists:foldl(fun({Id, mandatory}, M) ->
			case maps:is_key(Id, IEs) of
			    true  -> M;
			    false -> [Id | M]
			end;
		   (_, M) ->
			M
		end, [], Spec).

%%====================================================================
%% context registry
%%====================================================================

get_record_meta(#{context := Context} = Data) ->
    Tags0 = context2tags(Context),
    Tags = pfcp_tags(maps:get(pfcp, Data, undefined), Tags0),
    #{tags => Tags}.

context2tag(dnn, #context{apn = APN}, Meta) when APN /= undefined ->
    Meta#{dnn => APN};
context2tag(ip_domain, #context{vrf = #vrf{name = VRF}}, Meta) ->
    Meta#{ip_domain => VRF};
context2tag(ms_ips, #context{ms_v4 = MSv4, ms_v6 = MSv6}, Meta)
  when MSv4 /= undefined orelse MSv6 /= undefined ->
    Meta#{ipv4 => MSv4, ipv6 => MSv6};
context2tag(local_data_teid, #context{local_data_endp =
					  #gtp_endp{ip = LocalDataIP,
						    teid = LocalDataTEID}}, Meta) ->
    Meta#{local_data_tei => LocalDataTEID,
	  local_data_ip => LocalDataIP};
context2tag(remote_control_teid, #context{remote_control_teid =
				      #fq_teid{ip = RemoteIP,
					       teid = RemoteCntlTEID}}, Meta) ->
    Meta#{remote_control_tei => RemoteCntlTEID,
	  remote_control_ip => RemoteIP};
context2tag(remote_data_teid, #context{remote_data_teid =
				   #fq_teid{ip = RemoteIP,
					    teid = RemoteDataTEID}}, Meta) ->
    Meta#{remote_data_tei => RemoteDataTEID,
	  remote_data_ip => RemoteIP};
context2tag(_, _, Meta) ->
    Meta.

pfcp_tags(#pfcp_ctx{seid = #seid{cp = SEID}}, Meta) ->
    Meta#{seid => SEID};
pfcp_tags(_, Meta) ->
    Meta.

context2tags(#context{
		context_id          = ContextId,
		control_port        = #gtp_port{name = Name},
		local_control_tei   = LocalCntlTEID
	       } = Context) ->
    Meta =
	#{type => 'gtp-c',
	  port => Name,
	  local_control_tei => LocalCntlTEID,
	  context_id => ContextId},
    MetaF = [dnn, ip_domain, ms_ips, local_data_teid, remote_control_teid, remote_data_teid],
    lists:foldl(fun(K, M) -> context2tag(K, Context, M) end, Meta, MetaF).

context2keys(#context{
		apn                 = APN,
		context_id          = ContextId,
		control_port        = CntlPort,
		local_control_tei   = LocalCntlTEI,
		remote_control_teid = RemoteCntlTEID,
		vrf                 = #vrf{name = VRF},
		ms_v4               = MSv4,
		ms_v6               = MSv6
	       }) ->
    ordsets:from_list(
      [port_teid_key(CntlPort, 'gtp-c', LocalCntlTEI),
       port_teid_key(CntlPort, 'gtp-c', RemoteCntlTEID)]
      ++ [port_key(CntlPort, ContextId) || ContextId /= undefined]
      ++ [#bsf{dnn = APN, ip_domain = VRF, ip = ergw_ip_pool:ip(MSv4)} || MSv4 /= undefined]
      ++ [#bsf{dnn = APN, ip_domain = VRF,
	       ip = ergw_inet:ipv6_prefix(ergw_ip_pool:ip(MSv6))} || MSv6 /= undefined]);
context2keys(#context{
		context_id          = ContextId,
		control_port        = CntlPort,
		local_control_tei   = LocalCntlTEI,
		remote_control_teid = RemoteCntlTEID
	       }) ->
    ordsets:from_list(
      [port_teid_key(CntlPort, 'gtp-c', LocalCntlTEI),
       port_teid_key(CntlPort, 'gtp-c', RemoteCntlTEID)]
      ++ [port_key(CntlPort, ContextId) || ContextId /= undefined]).

port_key(#gtp_port{name = Name}, Key) ->
    #port_key{name = Name, key = Key}.

port_teid_key(#gtp_port{type = Type} = Port, TEI) ->
    port_teid_key(Port, Type, TEI).

port_teid_key(#gtp_port{name = Name}, Type, TEI) ->
    #port_teid_key{name = Name, type = Type, teid = TEI}.

save_session_state(#{'Session' := Session} = Data)
  when is_pid(Session) ->
    Data#{'Session' => ergw_aaa_session:save(Session)};
save_session_state(Data) ->
    Data.

restore_session_state(#{'Session' := Session} = Data)
  when not is_pid(Session) ->
    {ok, SessionPid} = ergw_aaa_session_sup:new_session(self(), Session),
    Data#{'Session' => SessionPid};
restore_session_state(Data) ->
    Data.

%%====================================================================
%% Experimental Trigger Support
%%====================================================================

usage_report_to_accounting(
  #{volume_measurement :=
	#volume_measurement{uplink = RcvdBytes, downlink = SendBytes},
    tp_packet_measurement :=
	#tp_packet_measurement{uplink = RcvdPkts, downlink = SendPkts}}) ->
    [{'InPackets',  RcvdPkts},
     {'OutPackets', SendPkts},
     {'InOctets',   RcvdBytes},
     {'OutOctets',  SendBytes}];
usage_report_to_accounting(
  #{volume_measurement :=
	#volume_measurement{uplink = RcvdBytes, downlink = SendBytes}}) ->
    [{'InOctets',   RcvdBytes},
     {'OutOctets',  SendBytes}];
usage_report_to_accounting(#usage_report_smr{group = UR}) ->
    usage_report_to_accounting(UR);
usage_report_to_accounting(#usage_report_sdr{group = UR}) ->
    usage_report_to_accounting(UR);
usage_report_to_accounting(#usage_report_srr{group = UR}) ->
    usage_report_to_accounting(UR);
usage_report_to_accounting([H|_]) ->
    usage_report_to_accounting(H);
usage_report_to_accounting(undefined) ->
    [].

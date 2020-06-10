%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_context).

%% API
-export([sx_report/1, port_message/2, port_message/3, port_message/4]).

%%-type ctx_ref() :: {Handler :: atom(), Server :: pid()}.
-type seid() :: 0..16#ffffffffffffffff.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

%%%=========================================================================
%%%  API
%%%=========================================================================

-callback sx_report(Server :: pid(), PFCP :: #pfcp{}) ->
    {ok, SEID :: seid()} |
    {ok, SEID :: seid(), Cause :: atom()} |
    {ok, SEID :: seid(), ResponseIEs :: map()}.

-callback port_message(Request :: #request{}, Msg :: #gtp{}) -> ok.

-callback port_message(Server :: pid(), Request :: #request{},
		       Msg :: #gtp{}, Resent :: boolean()) -> ok.

%%% -----------------------------------------------------------------

sx_report(#pfcp{type = session_report_request, seid = SEID} = Report) ->
    apply2context(#{tag => seid, value => SEID}, sx_report, [Report]).

%% port_message/2
port_message(Request, Msg) ->
    proc_lib:spawn(fun() -> port_message_h(Request, Msg) end),
    ok.

%% port_message/3
port_message(Keys0, #request{gtp_port = #gtp_port{name = Name}} = Request, Msg)
  when is_list(Keys0) ->
    Keys = [{Name, Key} || Key <- Keys0],
    apply2context(Keys, port_message, [Request, Msg, false]).

%% port_message/4
port_message(Key, Request, Msg, Resent) ->
    apply2context(Key, port_message, [Request, Msg, Resent]).

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

apply2context(RecordId, F, A) when is_binary(RecordId) ->
    case ergw_nudsf:get(block, RecordId, 1) of
	{ok, Context} ->
	    apply2context(RecordId, Context, F, A);
	_Other ->
	    ?LOG(debug, "unable to find context ~p", [RecordId]),
	    {error, not_found}
    end;

apply2context(Filter, F, A) when is_map(Filter) ->
    case ergw_nudsf:search(Filter) of
	{ok, _, [RecordId]} ->
	    apply2context(RecordId, F, A);
	_Other ->
	    ?LOG(debug, "unable to find context ~p", [Filter]),
	    {error, not_found}
    end.

apply2context(RecordId, #{handler := Handler} = Context, F, A) ->
    apply(Handler, F, [RecordId] ++ A ++ [Context]);
apply2context(_RecordId, _Context, _F, _A) ->
    {error, not_found}.

port_request_key(#request{key = ReqKey, gtp_port = GtpPort}) ->
    gtp_context:port_key(GtpPort, ReqKey).

%% TODO - MAYBE
%%  it might be benificial to first perform the lookup and then enqueue
%%
port_message_h(Request, #gtp{} = Msg) ->
    Queue = load_class(Msg),
    case jobs:ask(Queue) of
	{ok, Opaque} ->
	    try
		port_message_run(Request, Msg)
	    catch
		throw:{error, Error} ->
		    ?LOG(error, "handler failed with: ~p", [Error]),
		    gtp_context:generic_error(Request, Msg, Error)
	    after
		jobs:done(Opaque)
	    end;
	{error, Reason} ->
	    gtp_context:generic_error(Request, Msg, Reason)
    end.

port_message_run(Request, #gtp{type = g_pdu} = Msg) ->
    port_message_p(Request, Msg);
port_message_run(Request, Msg) ->
    %% check if this request is already pending
    case gtp_context_reg:lookup(port_request_key(Request)) of
	undefined ->
	    port_message_p(Request, Msg);
	_ ->
	    ok
    end.

port_message_p(#request{} = Request, #gtp{tei = 0} = Msg) ->
    gtp_context:port_message(Request, Msg);
port_message_p(#request{gtp_port = GtpPort} = Request, #gtp{tei = TEI} = Msg) ->
    case port_message(gtp_context:port_teid_key(GtpPort, TEI), Request, Msg, false) of
	{error, _} = Error ->
	    throw(Error);
	Result ->
	    Result
    end.

load_class(#gtp{version = v1} = Msg) ->
    gtp_v1_c:load_class(Msg);
load_class(#gtp{version = v2} = Msg) ->
    gtp_v2_c:load_class(Msg).

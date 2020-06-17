%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_context).

%% API
-export([sx_report/1, port_message/2, port_message/3,
	 create_context_record/3,
	 put_context_record/2,
	 get_context_record/1]).

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

-callback port_message(RecordId :: binary(), Request :: #request{},
		       Msg :: #gtp{}, Resent :: boolean()) -> ok.

%%% -----------------------------------------------------------------

%% TBD: use some kind of register?
handler(sx) -> ergw_sx_node;
handler(gtp) -> gtp_context;
handler(tdf) -> tdf.

sx_report(#pfcp{type = session_report_request, seid = SEID} = Report) ->
    apply2context(sx, #{tag => seid, value => SEID}, sx_report, [Report]).

%% port_message/2
port_message(Request, Msg) ->
    proc_lib:spawn(fun() -> port_message_h(Request, Msg) end),
    ok.

%% port_message/3
port_message(Keys0, #request{gtp_port = #gtp_port{name = Name}} = Request, Msg)
  when is_list(Keys0) ->
    Keys = [{Name, Key} || Key <- Keys0],
    ct:pal("Keys: ~p~nNudf: ~p", [Keys, ergw_nudsf:all()]),
    apply2context(gtp, Keys, port_message, [Request, Msg, false]).

%%%===================================================================
%%% Nudsf support
%%%===================================================================

create_context_record(State, Meta, #{record_id := RecordId} = Data) ->
    Serialized = serialize_block(#{state => State, data => Data}),
    ergw_nudsf:create(RecordId, Meta, #{<<"context">> => Serialized}).

put_context_record(State, #{record_id := RecordId} = Data) ->
    Serialized = serialize_block(#{state => State, data => Data}),
    ergw_nudsf:put(block, RecordId, <<"context">>, Serialized).

get_context_record(RecordId) ->
    case ergw_nudsf:get(block, RecordId, <<"context">>) of
	{ok, BlockBin} ->
	    case  deserialize_block(BlockBin) of
		#{state := State, data := Data} ->
		    {ok, State, Data};
		_ ->
		    {error, not_found}
	    end;
	_ ->
	    {error, not_found}
    end.

serialize_block(Data) ->
    term_to_binary(Data, [{minor_version, 2}, compressed]).

deserialize_block(Data) ->
    binary_to_term(Data, [safe]).

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

apply2context(Type, Filter, F, A) when is_map(Filter) ->
    %% TBD: query the local cache/registry first....
    ct:pal("Filter: ~p~nNudf: ~p~nSearch: ~p",
	   [Filter, ergw_nudsf:all(), (catch ergw_nudsf:search(Filter))]),
    case ergw_nudsf:search(Filter) of
	{1, [RecordId]} ->
	    apply(handler(Type), F, [RecordId] ++ A);
	_Other ->
	    ?LOG(debug, "unable to find context ~p -> ~p", [Filter, _Other]),
	    {error, not_found}
    end.

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
port_message_run(Request, Msg0) ->
    %% check if this request is already pending
    case gtp_context_reg:lookup(port_request_key(Request)) of
	undefined ->
	    ?LOG(info, "NO DUPLICATE REQEST"),
	    Msg = gtp_packet:decode_ies(Msg0),
	    port_message_p(Request, Msg);
	_Other ->
	    %% TBD.....
	    ct:pal("DUPLICATE REQUEST: ~p", [_Other]),
	    ok
    end.

port_message_p(#request{} = Request, #gtp{tei = 0} = Msg) ->
    gtp_context:port_message(Request, Msg);
port_message_p(#request{gtp_port = GtpPort} = Request, #gtp{tei = TEI} = Msg) ->
    Filter = gtp_context:port_teid_filter(GtpPort, TEI),
    case apply2context(gtp, Filter, port_message, [Request, Msg, false]) of
	{error, _} = Error ->
	    throw(Error);
	Result ->
	    Result
    end.

load_class(#gtp{version = v1} = Msg) ->
    gtp_v1_c:load_class(Msg);
load_class(#gtp{version = v2} = Msg) ->
    gtp_v2_c:load_class(Msg).

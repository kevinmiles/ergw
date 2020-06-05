%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_vnode).
-behaviour(riak_core_vnode).

-compile({parse_transform, cut}).

-export([start_vnode/1,
	 init/1,
	 terminate/2,
	 handle_command/3,
	 is_empty/1,
	 delete/1,
	 handle_handoff_command/3,
	 handoff_starting/2,
	 handoff_cancelled/1,
	 handoff_finished/2,
	 handle_handoff_data/2,
	 encode_handoff_item/2,
	 handle_overload_command/3,
	 handle_overload_info/2,
	 handle_coverage/4,
	 handle_exit/3]).
-export([port_message/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {partition, sup, tid, prefix}).

-define(MAX_TRIES, 32).

%%====================================================================
%% API
%%====================================================================

%% port message/2
port_message(Request, #gtp{tei = TEID} = Msg)
  when TEID /= 0 ->
    ?LOG(debug, "TEID: ~p", [TEID]),
    {ok, CHBin} = riak_core_ring_manager:get_chash_bin(),
    NumPartitions = chashbin:num_partitions(CHBin),
    Prefix = TEID bsr (32 - round(math:log2(NumPartitions))),
    ?LOG(debug, "Prefix: ~p", [Prefix]),
    Idx = riak_core_ring_util:partition_id_to_hash(Prefix, NumPartitions),
    Owner = chashbin:index_owner(Idx, CHBin),
    port_message({Idx, Owner}, Request, Msg);

port_message(Request, #gtp{tei = 0} = Msg0) ->
    Msg = gtp_packet:decode_ies(Msg0),
    Key = context_key(Msg),
    ?LOG(debug, "TEID 0 Key: ~p", [Key]),
    DocIdx = riak_core_util:chash_key({<<"gtp_context">>, term_to_binary(Key)}),
    PrefList = riak_core_apl:get_apl(DocIdx, 1, ergw),
    port_message(hd(PrefList), Request, Msg).

%%====================================================================
%% riak API
%%====================================================================

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) ->
    TID = ets:new(?MODULE, [ordered_set, private, {keypos, 1}]),
    {ok, SupRef} = gtp_context_sup_sup:new(),
    State0 = #state{partition = Partition, sup = SupRef, tid = TID},
    State = State0#state{prefix = init_tei_prefix(State0)},
    {ok, State}.

handle_command(ping, _Sender, #state{partition = Partition} = State) ->
    log("Received ping command ~p", [Partition], State),
    {reply, {pong, Partition}, State};
handle_command({port_message, Request, Msg}, Sender, #state{partition = Partition} = State) ->
    log("Received port message command ~p (~p, ~p)", [Partition, Request, Msg], State),
    port_message(Request, Msg, Sender, State);

handle_command(Message, _Sender, State) ->
    log("unhandled_command ~p", [Message], State),
    {noreply, State}.

handle_handoff_command(_Message, _Sender, State) ->
    {noreply, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(_Data, State) ->
    {reply, ok, State}.

encode_handoff_item(_ObjectName, _ObjectValue) ->
    <<>>.

handle_overload_command(_, _, _) ->
    ok.
handle_overload_info(_, _Idx) ->
    ok.

is_empty(#state{sup = Sup} = State) ->
    IsEmpty = (supervisor:which_children(Sup) =:= []),
    {IsEmpty, State}.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, #state{sup = Sup} = State) when is_pid(Sup) ->
    log("terminate with sup ~p", [Sup], State),
    gtp_context_sup_sup:stop(Sup),
    ok;
terminate(_Reason, _State) ->
    log("terminate without sup ~p", [_State], _State),
    ok.

%%====================================================================
%% ergw_context API
%%====================================================================

%% TEID handling for GTPv1 is brain dead....
port_message(Request, #gtp{version = v2, type = MsgType, tei = 0} = Msg, Sender, State)
  when MsgType == change_notification_request;
       MsgType == change_notification_response ->
    Keys = gtp_v2_c:get_msg_keys(Msg),
    port_message(Keys, Request, Msg, Sender, State);

%% same as above for GTPv2
port_message(Request, #gtp{version = v1, type = MsgType, tei = 0} = Msg, Sender, State)
  when MsgType == ms_info_change_notification_request;
       MsgType == ms_info_change_notification_response ->
    Keys = gtp_v1_c:get_msg_keys(Msg),
    port_message(Keys, Request, Msg, Sender, State);

port_message(#request{gtp_port = GtpPort} = Request,
	     #gtp{version = Version, tei = 0} = Msg, Sender, State) ->
    case get_handler_if(GtpPort, Msg) of
	{ok, Interface, InterfaceOpts} ->
	    case ergw:get_accept_new() of
		true -> ok;
		_ ->
		    throw({error, no_resources_available})
	    end,
	    validate_teid(Msg),
	    Server = context_new(GtpPort, Version, Interface, InterfaceOpts, State),
	    Reply = do_port_message(Server, Request, Msg, false),
	    {reply, Reply, State};

	{error, _} = Error ->
	    {reply, Error, State}
    end;
port_message(_Request, _Msg, _Sender, State) ->
    {reply, {error, not_found}, State}.

port_message([], _Request, _Msg, _Sender, State) ->
    {reply, {error, not_found}, State};
port_message([H|T], Request, Msg, Sender, State) ->
    case lookup(H, State) of
	[{_, TEI}] when is_integer(TEI) ->
	    case lookup_tei(TEI, Request, State) of
		[{_, Server}] when is_pid(Server) ->
		    Reply = do_port_message(Server, Request, Msg, false),
		    {reply, Reply, State};
		_ ->
		    {reply, {error, not_found}, State}
	    end;
	_ ->
	    port_message(T, Request, Msg, Sender, State)
    end.

%%====================================================================
%% Context Helpers
%%====================================================================

validate_teid(#gtp{version = v1, type = MsgType, tei = TEID}) ->
    gtp_v1_c:validate_teid(MsgType, TEID);
validate_teid(#gtp{version = v2, type = MsgType, tei = TEID}) ->
    gtp_v2_c:validate_teid(MsgType, TEID).

get_handler_if(GtpPort, #gtp{version = v1} = Msg) ->
    gtp_v1_c:get_handler(GtpPort, Msg);
get_handler_if(GtpPort, #gtp{version = v2} = Msg) ->
    gtp_v2_c:get_handler(GtpPort, Msg).

context_new(Port, Version, Interface, InterfaceOpts, #state{sup = Sup} = State) ->
    {ok, TEI} = alloc_tei(Port, State),
    case gtp_context_sup:new(Sup, Port, TEI, Version, Interface, InterfaceOpts) of
	{ok, Server} when is_pid(Server) ->
	    insert_tei(Port, TEI, Server, State),
	    Server;
	{error, Error} ->
	    throw({error, Error})
    end.

%% context_new(Port, Version, Interface, InterfaceOpts, State) ->
%%     TEI = alloc_tei(Port, State),
%%     gtp_context:init([Port, TEI, Version, Interface, InterfaceOpts]).

%% do_port_message/4
do_port_message(Server, Request, #gtp{type = g_pdu} = Msg, _Resent) ->
    gen_statem:cast(Server, {handle_pdu, Request, Msg});
do_port_message(Server, Request, Msg, Resent) ->
    %% if not Resent -> register_request(?MODULE, Server, Request);
    %%    true       -> ok
    %% end,
    gen_statem:cast(Server, {handle_message, Request, Msg, Resent}).

%%====================================================================
%% Internal Helpers
%%====================================================================

%% same as ?LOG(info, ...) but prepends the partition
log(String, Args, #state{partition = Partition}) ->
  String2 = "[~.36B] " ++ String,
  Args2 = [Partition | Args],
  ?LOG(info, String2, Args2),
  ok.

context_key(#gtp{version = v1} = Msg) ->
    context_key_1(gtp_v1_c:get_msg_keys(Msg));
context_key(#gtp{version = v2} = Msg) ->
    context_key_1(gtp_v2_c:get_msg_keys(Msg)).

context_key_1([{Type, Id, _}]) ->
    {Type, Id}.

maybe_init_rnd([]) ->
    rand:seed_s(exrop);
maybe_init_rnd([{_, RndState}]) ->
    RndState.

%% port message/3
port_message(IndexNode, Request, Msg) ->
    ?LOG(debug, "IndexNode: ~p", [IndexNode]),
    Command = {port_message, Request, Msg},
    riak_core_vnode_master:sync_spawn_command(IndexNode, Command, gtp_context_vnode_master).

%% with_keyfun/2
with_keyfun(#request{gtp_port = Port}, Fun) ->
    with_keyfun(Port, Fun);
with_keyfun(#gtp_port{name = Name} = Port, Fun) ->
    Fun(Name, gtp_context:port_teid_key(Port, _));
with_keyfun(#pfcp_ctx{name = Name} = PCtx, Fun) ->
    Fun(Name, ergw_pfcp:ctx_teid_key(PCtx, _)).

%% insert_tei/4
insert_tei(Port, TEI, Server, State) ->
    with_keyfun(Port, insert_tei(_, _, TEI, Server, State)).

%% insert_tei/5
insert_tei(_Name, KeyFun, TEI, Server, State) ->
    insert({KeyFun(TEI), Server}, State).

%% lookup_tei/3
lookup_tei(TEI, Request, State) ->
    with_keyfun(Request, lookup_tei(_, TEI, _, State)).

%% lookup_tei/4
lookup_tei(_Name, TEI, KeyFun, State) ->
    lookup(KeyFun(TEI), State).

%% alloc_tei/2
alloc_tei(Request, State) ->
    with_keyfun(Request, alloc_tei(_, _, State)).

%% alloc_tei/3
alloc_tei(Name, KeyFun, #state{tid = TID} = State) ->
    RndStateKey = {Name, tei},
    RndState = maybe_init_rnd(ets:lookup(TID, RndStateKey)),
    alloc_tei(RndStateKey, RndState, KeyFun, State, ?MAX_TRIES).

init_tei_prefix(#state{partition = Partition} = State) ->
    {ok, CHBin} = riak_core_ring_manager:get_chash_bin(),
    NumPartitions = chashbin:num_partitions(CHBin),
    PrefixLen = round(math:log2(NumPartitions)),
    Prefix = riak_core_ring_util:hash_to_partition_id(Partition, NumPartitions)
	bsl (32 - PrefixLen),
    Mask = 16#ffffffff bsr PrefixLen,
    log("Prefix: 0x~8.16.0b, Mask: 0x~8.16.0b", [Prefix, Mask], State),
    {Prefix, Mask}.

%% alloc_tei/5
alloc_tei(_RndStateKey, _RndState, _KeyFun, _State, 0) ->
    {error, no_tei};
alloc_tei(RndStateKey, RndState0, KeyFun, #state{prefix = {Prefix, Mask}} = State, Cnt) ->
    {TEI0, RndState} = rand:uniform_s(16#fffffffe, RndState0),
    TEI = Prefix + (TEI0 band Mask),
    case lookup(KeyFun(TEI), State) of
	[] ->
	    true = insert({RndStateKey, RndState}, State),
	    {ok, TEI};
	_ ->
	    alloc_tei(RndStateKey, RndState, KeyFun, State, Cnt - 1)
    end.

lookup(Key, #state{tid = TID}) ->
    ets:lookup(TID, Key).

insert(Value, #state{tid = TID}) ->
    ets:insert(TID, Value).

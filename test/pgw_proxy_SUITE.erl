%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_proxy_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("../include/ergw.hrl").

-define(HUT, pgw_s5s8_proxy).			%% Handler Under Test
-define(LOCALHOST, {127,0,0,1}).

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).

-define('APN-EXAMPLE', [<<"example">>, <<"net">>]).
-define('APN-PROXY',   [<<"proxy">>, <<"example">>, <<"net">>]).

-define('IMSI', <<"111111111111111">>).
-define('PROXY-IMSI', <<"222222222222222">>).
-define('MSISDN', <<"440000000000">>).
-define('PROXY-MSISDN', <<"491111111111">>).

-define(equal(Expected, Actual),
    (fun (Expected@@@, Expected@@@) -> true;
	 (Expected@@@, Actual@@@) ->
	     ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~p~n",
		    [?FILE, ?LINE, ??Actual, Expected@@@, Actual@@@]),
	     false
     end)(Expected, Actual) orelse error(badmatch)).

-define(match(Guard, Expr),
	((fun () ->
		  case (Expr) of
		      Guard -> ok;
		      V -> ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~p~n",
				   [?FILE, ?LINE, ??Expr, ??Guard, V]),
			    error(badmatch)
		  end
	  end)())).

%%%===================================================================
%%% API
%%%===================================================================

-define(TEST_CONFIG, [
		      %% {lager, [{colored, true},
		      %% 	       {handlers, [
		      %% 			   {lager_console_backend, debug},
		      %% 			   {lager_file_backend, [{file, "error.log"}, {level, error}]},
		      %% 			   {lager_file_backend, [{file, "console.log"}, {level, debug}]}
		      %% 			  ]}
		      %% 	      ]},

		      {ergw, [{sockets,
			       [{irx, [{type, 'gtp-c'},
				       {ip,  {127,0,0,1}},
				       {reuseaddr, true}
				      ]},
				{grx, [{type, 'gtp-u'},
				       {node, 'gtp-u-node@localhost'},
				       {name, 'grx'}
				      ]},
				{'proxy-irx', [{type, 'gtp-c'},
					       {ip,  {127,0,0,1}},
					       {reuseaddr, true},
					       {'$local_port',  ?GTP1c_PORT * 2},
					       {'$remote_port', ?GTP1c_PORT * 3}
					      ]},
				{'proxy-grx', [{type, 'gtp-u'},
					       {node, 'gtp-u-proxy@vlx161-tpmd'},
					       {name, 'proxy-grx'}
					      ]},
				{'remote-irx', [{type, 'gtp-c'},
						{ip,  {127,0,0,1}},
						{reuseaddr, true},
						{'$local_port',  ?GTP1c_PORT * 3},
						{'$remote_port', ?GTP1c_PORT * 2}
					       ]},
				{'remote-grx', [{type, 'gtp-u'},
						{node, 'gtp-u-node@localhost'},
						{name, 'grx'}
					       ]}
			       ]},

			      {vrfs,
			       [{example, [{pools,  [{{10, 180, 0, 1}, {10, 180, 255, 254}, 32},
						     {{16#8001, 0, 0, 0, 0, 0, 0, 0}, {16#8001, 0, 0, 16#FFFF, 0, 0, 0, 0}, 64}
						    ]},
					   {'MS-Primary-DNS-Server', {8,8,8,8}},
					   {'MS-Secondary-DNS-Server', {8,8,4,4}},
					   {'MS-Primary-NBNS-Server', {127,0,0,1}},
					   {'MS-Secondary-NBNS-Server', {127,0,0,1}}
					  ]}
			       ]},

			      {handlers,
			       %% proxy handler
			       [{gn, [{handler, ?HUT},
				      {sockets, [irx]},
				      {data_paths, [grx]},
				      {proxy_sockets, ['proxy-irx']},
				      {proxy_data_paths, ['proxy-grx']},
				      {pgw, {127,0,0,1}}
				     ]},
				{s5s8, [{handler, ?HUT},
					{sockets, [irx]},
					{data_paths, [grx]},
					{proxy_sockets, ['proxy-irx']},
					{proxy_data_paths, ['proxy-grx']},
					{pgw, {127,0,0,1}}
				       ]},
				%% remote PGW handler
				{gn, [{handler, pgw_s5s8},
				      {sockets, ['remote-irx']},
				      {data_paths, ['remote-grx']},
				      {aaa, [{'Username',
					      [{default, ['IMSI', <<"@">>, 'APN']}]}]}
				     ]},
				{s5s8, [{handler, pgw_s5s8},
					{sockets, ['remote-irx']},
					{data_paths, ['remote-grx']}
				       ]}
			       ]},

			      {apns,
			       [{?'APN-PROXY', [{vrf, example}]}
			       ]},

			      {proxy_map,
			       [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
				{imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
				       ]}
			       ]}
			     ]},
		      {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{secret, <<"MySecret">>}]}}]}
		     ]).


suite() ->
	[{timetrap,{seconds,30}}].

init_per_suite(Config) ->
    application:load(lager),
    application:load(ergw),
    application:load(ergw_aaa),
    ok = meck_dp(),
    ok = meck_socket('proxy-irx'),
    ok = meck_handler(),
    lists:foreach(fun({App, Settings}) ->
			  ct:pal("App: ~p, S: ~p", [App, Settings]),
			  lists:foreach(fun({K,V}) ->
						ct:pal("App: ~p, K: ~p, V: ~p", [App, K, V]),
						application:set_env(App, K, V)
					end, Settings)
		  end, ?TEST_CONFIG),
    {ok, _} = application:ensure_all_started(ergw),
    ok = meck:wait(gtp_dp, start_link, '_', 1000),
    Config.

end_per_suite(_) ->
    meck_unload(),
    application:stop(ergw),
    ok.

all() ->
    [invalid_gtp_pdu,
     create_session_request_missing_ie, create_session_request,
     create_session_request_resend,
     delete_session_request, delete_session_request_resend].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(_, Config) ->
    meck_reset(),
    %% gtp_fake_socket:take_ownership('proxy-irx'),
    Config.

end_per_testcase(_, Config) ->
    Config.

%%--------------------------------------------------------------------
invalid_gtp_pdu() ->
    [{doc, "Test that an invalid PDU is silently ignored"
      " and that the GTP socket is not crashing"}].
invalid_gtp_pdu(_Config) ->
    S = make_gtp_socket(),
    gen_udp:send(S, ?LOCALHOST, ?GTP2c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, 1000)),
    meck_validate(),
    ok.

%%--------------------------------------------------------------------
create_session_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_session_request_missing_ie(_Config) ->
    S = make_gtp_socket(),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    IEs = #{},
    Msg = #gtp{version = v2, type = create_session_request, tei = 0,
	       seq_no = SeqNo, ie = IEs},
    ok = send_pdu(S, Msg),

    Response =
	case gen_udp:recv(S, 4096, 1000) of
	    {ok, {?LOCALHOST, ?GTP2c_PORT, R}} ->
		R;
	    Unexpected ->
		ct:fail(Unexpected)
	end,

    ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = mandatory_ie_missing}}},
	   gtp_packet:decode(Response)),
    meck_validate(),
    ok.

create_session_request() ->
    [{doc, "Check that Create Session Request works"}].
create_session_request(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg = make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo),
    ok = send_pdu(S, Msg),

    Response =
	case gen_udp:recv(S, 4096, 1000) of
	    {ok, {?LOCALHOST, ?GTP2c_PORT, R}} ->
		R;
	    Unexpected ->
		ct:fail(Unexpected)
	end,

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo,
		ie = #{{v2_cause, 0} := #v2_cause{v2_cause = request_accepted}}},
	   gtp_packet:decode(Response)),
    meck_validate(),
    ok.

create_session_request_resend() ->
    [{doc, "Check that a retransmission of a Create Session Request works"}].
create_session_request_resend(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg = make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo),
    Resp = send_recv_pdu(S, Msg),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo,
		ie = #{{v2_cause, 0} := #v2_cause{v2_cause = request_accepted}}},
	   Resp),
    ?match(Resp, send_recv_pdu(S, Msg)),
    meck_validate(),
    ok.

delete_session_request() ->
    [{doc, "Check that Delete Session Request works"}].
delete_session_request(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo1 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo1,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		       {v2_fully_qualified_tunnel_endpoint_identifier,1} :=
			   #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-C PGW'},
		       {v2_bearer_context,0} :=
			   #v2_bearer_context{
			      group = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
					{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
					    #v2_fully_qualified_tunnel_endpoint_identifier{
					       interface_type = ?'S5/S8-U PGW'}}}
		      }}, Resp1),

    #gtp{ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		    #v2_fully_qualified_tunnel_endpoint_identifier{
		       key = RemoteCntlTEI},
		{v2_bearer_context,0} :=
		    #v2_bearer_context{
		       group = #{{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
				     #v2_fully_qualified_tunnel_endpoint_identifier{
					key = _RemoteDataTEI}}}
	       }} = Resp1,

    SeqNo2 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    Msg2 = make_delete_session_request(LocalCntlTEI, RemoteCntlTEI, SeqNo2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo2,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Resp2),
    ok = meck:wait(?HUT, terminate, '_', 1000),
    meck_validate(),
    ok.

delete_session_request_resend() ->
    [{doc, "Check that a retransmission of a Delete Session Request works"}].
delete_session_request_resend(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo1 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo1,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		       {v2_fully_qualified_tunnel_endpoint_identifier,1} :=
			   #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-C PGW'},
		       {v2_bearer_context,0} :=
			   #v2_bearer_context{
			      group = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
					{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
					    #v2_fully_qualified_tunnel_endpoint_identifier{
					       interface_type = ?'S5/S8-U PGW'}}}
		      }}, Resp1),

    #gtp{ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		    #v2_fully_qualified_tunnel_endpoint_identifier{
		       key = RemoteCntlTEI},
		{v2_bearer_context,0} :=
		    #v2_bearer_context{
		       group = #{{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
				     #v2_fully_qualified_tunnel_endpoint_identifier{
					key = _RemoteDataTEI}}}
	       }} = Resp1,

    SeqNo2 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    Msg2 = make_delete_session_request(LocalCntlTEI, RemoteCntlTEI, SeqNo2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo2,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Resp2),
    ?match(Resp2, send_recv_pdu(S, Msg2)),
    ok = meck:wait(?HUT, terminate, '_', 1000),
    meck_validate(),
    ok.

%%%===================================================================
%%% Meck functions for fake the GTP sockets
%%%===================================================================

meck_dp() ->
    ok = meck:new(gtp_dp, [passthrough, no_link]),
    ok = meck:expect(gtp_dp, start_link, fun({Name, _SocketOpts}) ->
						 RCnt =  erlang:unique_integer([positive, monotonic]) rem 256,
						 GtpPort = #gtp_port{name = Name,
								     type = 'gtp-u',
								     pid = self(),
								     ip = ?LOCALHOST,
								     restart_counter = RCnt},
						 gtp_socket_reg:register(Name, GtpPort),
						 {ok, self()}
					 end),
    ok = meck:expect(gtp_dp, send, fun(_GtpPort, _IP, _Port, _Data) -> ok end),
    ok = meck:expect(gtp_dp, get_id, fun(_GtpPort) -> self() end),
    ok = meck:expect(gtp_dp, create_pdp_context, fun(_Context, _Args) -> ok end),
    ok = meck:expect(gtp_dp, update_pdp_context, fun(_Context, _Args) -> ok end),
    ok = meck:expect(gtp_dp, delete_pdp_context, fun(_Context, _Args) -> ok end).

meck_socket(_SocketName) ->
    ok = meck:new(gtp_socket, [passthrough, no_link]),
    %% ok = meck:expect(gtp_socket, start_link, fun(Opts = {Name, _SocketOpts})
    %% 						   when Name =:= SocketName ->
    %% 						     ct:pal("Fake Socket Opts: ~p", [Opts]),
    %% 						     gtp_fake_socket:start_link(Opts);
    %% 						(Opts) ->
    %% 						     ct:pal("Socket Opts: ~p", [Opts]),
    %% 						     meck:passthrough([Opts])
    %% 					     end).
    ok.

meck_handler() ->
    ok = meck:new(?HUT, [passthrough, no_link]).

meck_reset() ->
    meck:reset(gtp_dp),
    meck:reset(gtp_socket),
    meck:reset(?HUT).

meck_unload() ->
    meck:unload(gtp_dp),
    meck:unload(gtp_socket),
    meck:unload(?HUT).

meck_validate() ->
    ct:pal("Socket History: ~p", [meck:history(gtp_socket)]),
    ?equal(true, meck:validate(gtp_socket)),
    ct:pal("~s History: ~p", [?HUT, meck:history(?HUT)]),
    ?equal(true, meck:validate(?HUT)).

%%%===================================================================
%%% Internal functions
%%%===================================================================

make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo) ->
    IEs = [#v2_access_point_name{apn = ?'APN-EXAMPLE'},
	   #v2_aggregate_maximum_bit_rate{uplink = 48128, downlink = 1704125},
	   #v2_apn_restriction{restriction_type_value = 0},
	   #v2_bearer_context{
	      group = [#v2_bearer_level_quality_of_service{
			  pci = 1, pl = 10, pvi = 0, label = 8,
			  maximum_bit_rate_for_uplink      = 0,
			  maximum_bit_rate_for_downlink    = 0,
			  guaranteed_bit_rate_for_uplink   = 0,
			  guaranteed_bit_rate_for_downlink = 0},
		       #v2_eps_bearer_id{eps_bearer_id = 5},
		       #v2_fully_qualified_tunnel_endpoint_identifier{
			  instance = 2,
			  interface_type = ?'S5/S8-U SGW',
			  key = LocalDataTEI,
			  ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)}
		      ]},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #v2_international_mobile_subscriber_identity{
	      imsi = ?'IMSI'},
	   #v2_mobile_equipment_identity{mei = <<"AAAAAAAA">>},
	   #v2_msisdn{msisdn = ?'MSISDN'},
	   #v2_pdn_address_allocation{type = ipv4,
				      address = <<0,0,0,0>>},
	   #v2_pdn_type{pdn_type = ipv4},
	   #v2_protocol_configuration_options{
	      config = {0, [{ipcp,'CP-Configure-Request',0,[{ms_dns1,<<0,0,0,0>>},
							    {ms_dns2,<<0,0,0,0>>}]},
			    {13,<<>>},{10,<<>>},{5,<<>>}]}},
	   #v2_rat_type{rat_type = 6},
	   #v2_selection_mode{mode = 0},
	   #v2_serving_network{mcc = <<"001">>, mnc = <<"001">>},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = create_session_request, tei = 0,
	 seq_no = SeqNo, ie = IEs}.

make_delete_session_request(LocalCntlTEI, RemoteCntlTEI, SeqNo) ->
    IEs = [%%{170,0} => {170,0,<<220,126,139,67>>},
	   #v2_eps_bearer_id{eps_bearer_id = 5},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = delete_session_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

make_gtp_socket() ->
    {ok, S} = gen_udp:open(0, [{ip, ?LOCALHOST}, {active, false},
			       binary, {reuseaddr, true}]),
    S.

send_pdu(S, Msg) ->
    Data = gtp_packet:encode(Msg),
    gen_udp:send(S, ?LOCALHOST, ?GTP2c_PORT, Data).

send_recv_pdu(S, Msg) ->
    ok = send_pdu(S, Msg),

    Response =
	case gen_udp:recv(S, 4096, 1000) of
	    {ok, {?LOCALHOST, ?GTP2c_PORT, R}} ->
		R;
	    Unexpected ->
		ct:fail(Unexpected)
	end,
    gtp_packet:decode(Response).
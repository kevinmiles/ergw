%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(dhcp_pool_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("kernel/include/logger.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("dhcp/include/dhcp.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").

-define(TIMEOUT, 2000).

%%%===================================================================
%%% Config
%%%===================================================================

-define(TEST_CONFIG,
	[
	 {kernel,
	  [{logger,
	    [%% force cth_log to async mode, never block the tests
	     {handler, cth_log_redirect, cth_log_redirect,
	      #{level => all,
		config =>
		    #{sync_mode_qlen => 10000,
		      drop_mode_qlen => 10000,
		      flush_qlen     => 10000}
	       }
	     }
	    ]}
	  ]},

	 {dhcp,
	  [{server_id, {127,0,0,1}},
	   {next_server, {127,0,0,1}},
	   {interface, <<"lo">>},
	   {authoritative, true},
	   {lease_file, "/var/run/dhcp_leases.dets"},
	   {subnets,
	    [{subnet,
	      {172,20,48,0},                       %% Network,
	      {255,255,255,0},                     %% Netmask,
	      {{172,20,48,5},{172,20,48,100}},     %% Range,
	      [{1,  {255,255,255,0}},              %% Subnet Mask,
	       {28, {172,20,48,255}},              %% Broadcast Address,
	       {3,  [{172,20,48,1}]},              %% Router,
	       {15, "wlan"},                       %% Domain Name,
	       {6,  [{172,20,48,1}]},              %% Domain Name Server,
	       {51, 3600},                         %% Address Lease Time,
	       {58, 5}]}                          %% DHCP Renewal Time,
	    ]}
	  ]},

	 {dhcpv6,
	  [{server_id, {4, <<112,239,124,234,172,81,85,194,223,29,48,191,218,176,68,242>>}},
	   {next_server, ?LOCALHOST_IPv6},
	   {socket, #{%%netdev => "lo",
		      ip     => any,
		      join   => {0, [local, all_dhcp_servers, all_dhcp_relay_agents_and_servers]}}},
	   {authoritative, true},
	   {lease_file, "/var/run/dhcpv6_leases"},
	   {subnets,
	    [#{subnet  => ?IPv6PoolNet,
	       options => [{23, [?LOCALHOST_IPv6]}],              %% Domain Name Server,
	       pools   =>
		   [#{pool    => {?IPv6HostPoolStart, ?IPv6HostPoolEnd},
		      options => []}],
	       pd_pools =>
		   [#{prefix        => ?IPv6PoolStart,
		      prefix_len    => 48,
		      delegated_len => 64,
		      options       => []}]
	      }
	    ]}
	  ]},

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {sockets,
		  [{'cp-socket',
			[{type, 'gtp-u'},
			 {vrf, cp},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},
		   {'irx-socket',
			 [{type, 'gtp-c'},
			  {vrf, irx},
			  {ip, ?MUST_BE_UPDATED},
			  {reuseaddr, true}
			 ]},

		   {sx, [{type, 'pfcp'},
			 {node, 'ergw'},
			 {name, 'ergw'},
			 {socket, 'cp-socket'},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},

		   {'dhcp-v4',
		    [{type, dhcp},
		     %%{ip, ?MUST_BE_UPDATED},
		     {ip, {127,100,0,1}},
		     {port, random},
		     {reuseaddr, true}
		    ]},
		   {'dhcp-v6',
		    [{type, dhcp},
		     %%{ip, ?MUST_BE_UPDATED},
		     {ip, #{family => inet6, addr => any, port => random}},
		     {reuseaddr, true}
		    ]}
		  ]},

		 {ip_pools,
		  [{'pool-A', [{handler, ergw_dhcp_pool},
			       {ipv4, [{socket, 'dhcp-v4'},
				       {id, {172,20,48,1}},
				       {servers, [broadcast]}]},
			       {ipv6, [{socket, 'dhcp-v6'},
				       {id, {16#8001, 0, 1, 0, 0, 0, 0, 0}},
				       {servers, [local]}]}
			      ]}
		  ]},

		 {handlers,
		  [{gn, [{handler, pgw_s5s8},
			 {sockets, ['irx-socket']},
			 {node_selection, [default]}
			]},
		   {s5s8, [{handler, pgw_s5s8},
			   {sockets, ['irx-socket']},
			   {node_selection, [default]}
			  ]}
		  ]},

		 {apns,
		  [{'_', [{vrf, sgi}, {ip_pools, ['pool-A']}]}]},

		 {nodes,
		  [{default,
		    [{vrfs,
		      [{cp, [{features, ['CP-Function']}]},
		       {irx, [{features, ['Access']}]},
		       {sgi, [{features, ['SGi-LAN']}]}
		      ]},
		     {ip_pools, ['pool-A']}
		    ]}
		  ]}
		]},

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      [{'NAS-Identifier',          <<"NAS-Identifier">>},
	       {'Node-Id',                 <<"PGW-001">>},
	       {'Charging-Rule-Base-Name', <<"m2m0001">>},
	       {'Acct-Interim-Interval',  600}
	      ]}
	    ]},
	   {services,
	    [{'Default',
	      [{handler, 'ergw_aaa_static'}]}]}
	  ]}
	]).

-define(CONFIG_UPDATE,
	[{[sockets, 'cp-socket', ip], localhost},
	 {[sockets, 'irx-socket', ip], test_gsn},
	 {[sockets, sx, ip], localhost}
%% ,
%% 	 {[dhcp_socket, ip], localhost}
	]).

%%%===================================================================
%%% Setup
%%%===================================================================

suite() ->
    [{timetrap,{seconds,30}}].

dhcp_init_per_suite(Group, Config) ->
    {_, AppCfg} = lists:keyfind(app_cfg, 1, Config),   %% let it crash if undefined

    [application:load(App) || App <- [cowboy, ergw, ergw_aaa, dhcp, dhcpv6]],
    load_config(AppCfg),
    case Group of
	ipv4 -> {ok, _} = application:ensure_all_started(dhcp);
	ipv6 -> {ok, _} = application:ensure_all_started(dhcpv6)
    end,
    {ok, _} = application:ensure_all_started(ergw),
    Config.

dhcp_end_per_suite(_Config) ->
    [application:stop(App) || App <- [ranch, cowboy, ergw, ergw_aaa, dhcp]],
    ok.

init_per_suite(Config) ->
    logger:set_primary_config(#{level => debug}),
    [{app_cfg, ?TEST_CONFIG} | Config].

end_per_suite(_Config) ->
    ok.

init_per_group(ipv6, Config0) ->
    case ergw_test_lib:has_ipv6_test_config() of
	true ->
	    Config = update_app_config(ipv6, ?CONFIG_UPDATE, Config0),
	    dhcp_init_per_suite(ipv6, Config);
	_ ->
	    {skip, "IPv6 test IPs not configured"}
    end;
init_per_group(ipv4, Config0) ->
    Config = update_app_config(ipv4, ?CONFIG_UPDATE, Config0),
    dhcp_init_per_suite(ipv4, Config).

end_per_group(Group, Config)
  when Group == ipv4; Group == ipv6 ->
    ok = dhcp_end_per_suite(Config).

groups() ->
    [{ipv4, [], [dhcpv4, v4_renew]},
     {ipv6, [], [dhcpv6, v6_renew, v6_rebind]}].

all() ->
    [{group, ipv4},
     {group, ipv6}].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, Config) ->
    Config.

%%--------------------------------------------------------------------
dhcpv4() ->
    [{doc, "Test simple dhcpv4 requests"}].
dhcpv4(_Config) ->
    ClientId = <<"aaaaa">>,
    Pool = <<"pool-A">>,
    IP = ipv4,
    PrefixLen = 32,
    Opts = #{'MS-Primary-DNS-Server' => true,
	     'MS-Secondary-DNS-Server' => true},

    ReqId = ergw_ip_pool:send_request(ClientId, [{Pool, IP, PrefixLen, Opts}]),
    [AllocInfo] = ergw_ip_pool:wait_response(ReqId),
    ?match({ergw_dhcp_pool, _, {{_,_,_,_}, 32}, _, #{'MS-Primary-DNS-Server' := {_,_,_,_}}},
	   AllocInfo),

    ergw_ip_pool:release([AllocInfo]),
    ct:sleep(100),
    ok.

%--------------------------------------------------------------------
v4_renew() ->
    [{doc, "Test simple dhcpv4 requests"}].
v4_renew(_Config) ->
    ClientId = <<"aaaaa">>,
    Pool = <<"pool-A">>,
    IP = ipv4,
    PrefixLen = 32,
    Opts = #{'MS-Primary-DNS-Server' => true,
	     'MS-Secondary-DNS-Server' => true},

    ReqId = ergw_ip_pool:send_request(ClientId, [{Pool, IP, PrefixLen, Opts}]),
    [AllocInfo] = ergw_ip_pool:wait_response(ReqId),
    ?match({ergw_dhcp_pool, _, {{_,_,_,_}, 32}, _, #{'MS-Primary-DNS-Server' := {_,_,_,_}}},
	   AllocInfo),

    ergw_ip_pool:handle_event(AllocInfo, renewal),
    ct:sleep({seconds, 1}),

    ergw_ip_pool:release([AllocInfo]),
    ct:sleep(100),
    ok.

%%--------------------------------------------------------------------
dhcpv6() ->
    [{doc, "Test simple dhcpv6 requests"}].
dhcpv6(_Config) ->
    ct:pal("All: ~p", [ergw_socket_reg:all()]),
    inet:i(),
    ClientId = <<"aaaaa">>,
    Pool = <<"pool-A">>,
    IP = ipv6,
    PrefixLen = 64,
    Opts = #{'DNS-Server-IPv6-Address' => true},

    ReqId = ergw_ip_pool:send_request(ClientId, [{Pool, IP, PrefixLen, Opts}]),
    [AllocInfo] = ergw_ip_pool:wait_response(ReqId),
    ?match({ergw_dhcp_pool, _, {{_,_,_,_,_,_,_,_}, 64}, _,
	    #{'DNS-Server-IPv6-Address' := [{_,_,_,_,_,_,_,_}|_]}},
	   AllocInfo),

    ergw_ip_pool:release([AllocInfo]),
    ct:sleep(100),
    ok.

%--------------------------------------------------------------------
v6_renew() ->
    [{doc, "Test simple dhcpv6 requests"}].
v6_renew(_Config) ->
    ClientId = <<"aaaaa">>,
    Pool = <<"pool-A">>,
    IP = ipv6,
    PrefixLen = 64,
    Opts = #{'DNS-Server-IPv6-Address' => true},

    ReqId = ergw_ip_pool:send_request(ClientId, [{Pool, IP, PrefixLen, Opts}]),
    [AllocInfo] = ergw_ip_pool:wait_response(ReqId),
    ?match({ergw_dhcp_pool, _, {{_,_,_,_,_,_,_,_}, 64}, _,
	    #{'DNS-Server-IPv6-Address' := [{_,_,_,_,_,_,_,_}|_]}},
	   AllocInfo),

    ergw_ip_pool:handle_event(AllocInfo, renewal),
    ct:sleep({seconds, 1}),

    ergw_ip_pool:release([AllocInfo]),
    ct:sleep(100),
    ok.

%--------------------------------------------------------------------
v6_rebind() ->
    [{doc, "Test simple dhcpv6 requests"}].
v6_rebind(_Config) ->
    ClientId = <<"aaaaa">>,
    Pool = <<"pool-A">>,
    IP = ipv6,
    PrefixLen = 64,
    Opts = #{'DNS-Server-IPv6-Address' => true},

    ReqId = ergw_ip_pool:send_request(ClientId, [{Pool, IP, PrefixLen, Opts}]),
    [AllocInfo] = ergw_ip_pool:wait_response(ReqId),
    ?match({ergw_dhcp_pool, _, {{_,_,_,_,_,_,_,_}, 64}, _,
	    #{'DNS-Server-IPv6-Address' := [{_,_,_,_,_,_,_,_}|_]}},
	   AllocInfo),

    ergw_ip_pool:handle_event(AllocInfo, rebinding),
    ct:sleep({seconds, 1}),

    ergw_ip_pool:release([AllocInfo]),
    ct:sleep(100),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

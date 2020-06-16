%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% simple implementation of 3GPP TS 29.598 Nudsf service
%% - functional API according to TS
%% - not optimized for anything

-module(ergw_nudsf_mongo).

-behavior(ergw_nudsf_api).

-compile({parse_transform, cut}).

%% API
-export([get_childspecs/1,
	 get/2, get/3,
	 search/1,
	 create/3, create/4,
	 put/3, put/4,
	 delete/2, delete/3,
	 all/0,
	 validate_options/1]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ergw_nudsf_mongo_srv).
-define(POOL, ergw_nudsf_mongo_pool).

%%%=========================================================================
%%%  API
%%%=========================================================================

get_childspecs(AppConfig) ->
    Config = proplists:get_value(udsf, AppConfig),
    DB0 = maps:get(database, Config),
    Pool = maps:get(pool, Config),

    DB = maps:to_list(maps:remove(host, DB0)),
    Seeds = {unknown, [maps:get(host, DB0)]},
    Options = [{name, {local, ?POOL}},
	       {register, ?SERVER}
	      | maps:to_list(Pool)],
    ?LOG(debug, "DB: ~p~nSeeds: ~p~nOptions: ~p~n", [DB, Seeds, Options]),

    [#{id       => ?SERVER,
       start    => {mongoc, connect, [Seeds, Options, DB]},
       restart  => permanent,
       shutdown =>  5000,
       type     => supervisor,
       modules  => [mongoc]}].

%% TS 29.598, 5.2.2.2 Query

get(record, RecordId) ->
    ?LOG(debug, "get(block, ~p)", [RecordId]),
    Selector = #{<<"_id">> => RecordId},
    Projection = #{},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find_one(?SERVER, <<"Nudfs">>, Selector, Projection) of
	#{<<"meta">> := Meta, <<"blocks">> := Blocks} = R ->
	    ?LOG(debug, "get(..) -> ~p", [R]),
	    {ok, Meta, maps:map(fun get_block/2, Blocks)};
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end;
get(meta, RecordId) ->
    ?LOG(debug, "get(block, ~p)", [RecordId]),
    Selector = #{<<"_id">> => RecordId},
    Projection = #{<<"meta">> => 1},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find_one(?SERVER, <<"Nudfs">>, Selector, Projection) of
	#{<<"meta">> := Meta} = R ->
	    ?LOG(debug, "get(..) -> ~p", [R]),
	    {ok, Meta};
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end;
get(blocks, RecordId) ->
    ?LOG(debug, "get(block, ~p)", [RecordId]),
    Selector = #{<<"_id">> => RecordId},
    Projection = #{"blocks" => 1},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find_one(?SERVER, <<"Nudfs">>, Selector, Projection) of
	#{<<"blocks">> := Blocks} = R ->
	    ?LOG(debug, "get(..) -> ~p", [R]),
	    {ok, maps:map(fun get_block/2, Blocks)};
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end.

get(block, RecordId, BlockId) ->
    ?LOG(debug, "get(block, ~p, ~p)", [RecordId, BlockId]),
    Selector = #{<<"_id">> => RecordId},
    Projection = #{<<"blocks.", BlockId/binary>> => 1},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find_one(?SERVER, <<"Nudfs">>, Selector, Projection) of
	#{<<"blocks">> := #{BlockId := Block}} = R ->
	    ?LOG(debug, "get(..) -> ~p", [R]),
	    {ok, get_block(BlockId, Block)};
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end.

%% TS 29.598, 5.2.2.2.6	Search

search(Filter) ->
    ?LOG(debug, "search(~p)", [Filter]),
    Selector = search_expr(Filter),
    Projection = #{<<"_id">> => 1},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find(?SERVER, <<"Nudfs">>, Selector, Projection) of
	{ok, Cursor} = R ->
	    ?LOG(debug, "search(..) -> ~p", [R]),
	    Result =
		case mc_cursor:rest(Cursor) of
		    List when is_list(List) ->
			[Id || #{<<"_id">> := Id} <- List];
		    _Other ->
			?LOG(error, "MongoDB.find() failed with ~p", [_Other]),
			[]
		end,
	    mc_cursor:close(Cursor),
	    ?LOG(debug, "search(..) -> ~p", [Result]),
	    Result;
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end.


%% TS 29.598, 5.2.2.3 Create

create(RecordId, Meta, Blocks) ->
    ?LOG(debug, "create(~p, ~p, ~p)", [RecordId, Meta, Blocks]),
    Doc = #{<<"_id">> => RecordId,
	    <<"meta">> => Meta,
	    <<"blocks">> => maps:map(fun put_block/2, Blocks)
	   },
    ?LOG(debug, "create(..): ~p", [Doc]),
    R = (catch mongo_api:insert(?SERVER, <<"Nudfs">>, Doc)),
    ?LOG(debug, "create(..) -> ~p", [R]),
    ok.

create(block, RecordId, BlockId, Block) ->
    ?LOG(debug, "create(block, ~p, ~p, ~p)", [block, RecordId, BlockId, Block]),
    put(block, RecordId, BlockId, Block).

%% TS 29.598, 5.2.2.4 Update
put(record, RecordId, Meta, Blocks) ->
    ?LOG(debug, "put(record, ~p, ~p, ~p)", [RecordId, Meta, Blocks]),
    Selector = #{<<"_id">> => RecordId},
    Doc = #{<<"_id">> => RecordId,
	    <<"meta">> => Meta,
	    <<"blocks">> => maps:map(fun put_block/2, Blocks)
	   },
    update_one(Selector, Doc);

put(block, RecordId, BlockId, Block) ->
    ?LOG(debug, "put(block, ~p, ~p, ~p)", [RecordId, BlockId, Block]),
    Selector = #{<<"_id">> => RecordId},
    Blocks = #{<<"blocks.", BlockId/binary>> => Block},
    Doc = #{<<"$set">> => maps:map(fun put_block/2, Blocks)},
    update_one(Selector, Doc).

put(meta, RecordId, Meta) ->
    ?LOG(debug, "put(meta, ~p, ~p)", [RecordId, Meta]),
    Selector = #{<<"_id">> => RecordId},
    Doc = #{<<"$set">> => #{<<"meta">> => Meta}},
    update_one(Selector, Doc).

%% TS 29.598, 5.2.2.5 Delete

delete(record, RecordId) ->
   ?LOG(debug, "delete(record, ~p)", [RecordId]),
    Selector = #{<<"_id">> => RecordId},
    ?LOG(debug, "delete(..): ~p, ~p", [Selector]),
    case mongo_api:delete(?SERVER, <<"Nudfs">>, Selector) of
	{true, #{<<"n">> := 1}} = R ->
	    ?LOG(debug, "put(..) -> ~p", [R]),
	    ok;
	{_, Result} = R ->
	    ?LOG(debug, "put(..) -> ~p", [R]),
	    ?LOG(error, "MongoDB.delete() failed with ~p", [Result]),
	    {error, failed}
    end.

delete(block, RecordId, BlockId) ->
    ?LOG(debug, "delete(block, ~p, ~p)", [RecordId, BlockId]),
    Selector = #{<<"_id">> => RecordId},
    Doc = #{<<"$unset">> => [<<"blocks.", BlockId/binary>>]},
    update_one(Selector, Doc).

all() ->
    ?LOG(debug, "all()"),
    Selector = #{},
    Projection = #{},
    ?LOG(debug, "all(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find(?SERVER, <<"Nudfs">>, Selector, Projection) of
	{ok, Cursor} = R ->
	    ?LOG(debug, "all(..) -> ~p", [R]),
	    Result = mc_cursor:rest(Cursor),
	    mc_cursor:close(Cursor),
	    ?LOG(debug, "all(..) -> ~p", [Result]),
	    Result;
	_Other ->
	    ?LOG(debug, "all(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.find() failed with ~p", [_Other]),
	    {error, not_found}
    end.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(Defaults, [{pool, []}, {database, []}]).
-define(DefaultsPool, [{size, 5}, {max_overflow, 10}]).
-define(DefaultsDB, [{host, <<"localhost:27017">>},
		     {database, <<"ergw">>},
		     {login, undefined},
		     {password, undefined}]).

validate_options(Values) ->
    ?LOG(debug, "Mongo Options: ~p", [Values]),
    ergw_config:validate_options(fun validate_option/2, Values, ?Defaults, map).

validate_option(handler, Value) ->
    Value;
validate_option(pool, Values) ->
    ergw_config:validate_options(fun validate_pool_option/2, Values, ?DefaultsPool, map);
validate_option(database, Values) ->
    ergw_config:validate_options(fun validate_database_option/2, Values, ?DefaultsDB, map);

validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_pool_option(size, Value) when is_integer(Value) ->
    Value;
validate_pool_option(max_overflow, Value) when is_integer(Value) ->
    Value;
validate_pool_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_database_option(host, Value) when is_binary(Value) ->
    Value;
validate_database_option(database, Value) when is_binary(Value) ->
    Value;
validate_database_option(login, Value) when is_binary(Value); Value =:= undefined ->
    Value;
validate_database_option(password, Value) when is_binary(Value); Value =:= undefined ->
    Value;
validate_database_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

put_block(_, V) ->
    {bin, bin, V}.

get_block(_, {bin, bin, V}) ->
    V.

update_one(Selector, Doc) ->
    ?LOG(debug, "put(..): ~p, ~p", [Selector, Doc]),
    case mongo_api:update(?SERVER, <<"Nudfs">>, Selector, Doc, #{}) of
	{true, #{<<"n">> := 1}} = R ->
	    ?LOG(debug, "put(..) -> ~p", [R]),
	    ok;
	{_, Result} = R ->
	    ?LOG(debug, "put(..) -> ~p", [R]),
	    ?LOG(error, "MongoDB.update() failed with ~p", [Result]),
	    {error, failed}
    end.

search_expr(Expr) ->
    search_expr(Expr, #{}).

search_expr(#{'cond' := Cond, units := Units}, Query) ->
    search_expr(Cond, Units, Query);

search_expr(#{tag := Tag, value := Value} = Cond, Query) ->
    search_cond(Tag, Value, maps:get(op, Cond, 'EQ'), Query).

search_expr('NOT', [Expr], Query) ->
    Query#{<<"$nor">> => search_expr(Expr)};

search_expr('OR', Exprs, Query) ->
    Query#{<<"$or">> => lists:map(fun search_expr/1, Exprs)};

search_expr('AND', Exprs, Query) ->
    Query#{<<"$and">> => lists:map(fun search_expr/1, Exprs)}.

meta_tag_query(Tag, Value, Query) ->
    Key = iolist_to_binary(io_lib:format("meta.tags.~s", [Tag])),
    maps:put(Key, Value, Query).

search_cond(Tag, Value, 'EQ', Query)  -> meta_tag_query(Tag, Value, Query);
search_cond(Tag, Value, 'NEQ', Query) -> meta_tag_query(Tag, #{<<"$ne">> => Value}, Query);
search_cond(Tag, Value, 'GT', Query)  -> meta_tag_query(Tag, #{<<"$gt">> => Value}, Query);
search_cond(Tag, Value, 'GTE', Query) -> meta_tag_query(Tag, #{<<"$gte">> => Value}, Query);
search_cond(Tag, Value, 'LT', Query)  -> meta_tag_query(Tag, #{<<"$lt">> => Value}, Query);
search_cond(Tag, Value, 'LTE', Query) -> meta_tag_query(Tag, #{<<"$lte">> => Value}, Query).

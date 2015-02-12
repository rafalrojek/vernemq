%% Copyright 2014 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(vmq_config).

-behaviour(gen_server).

%% API
-export([start_link/0,
         change_config/1,
         configure_node/0,
         table_defs/0,
         get_env/1,
         get_env/2,
         get_env/3,
         set_env/2,
         set_env/3,
         get_all_env/1
        ]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(vmq_config, {key, % {node(), app_name(), item_name()}
                     val,
                     short_descr,
                     long_descr,
                     vclock=unsplit_vclock:fresh()}).

-define(TABLE, vmq_config_cache).
-define(MNESIA, ?MODULE).



%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_env(Key) ->
    get_env(vmq_server, Key, undefined).

get_env(Key, Default) ->
    get_env(vmq_server, Key, Default).

get_env(App, Key, Default) ->
    case ets:lookup(?TABLE, {App, Key}) of
        [{_, Val}] -> Val;
        [] ->
            Val =
            case mnesia:dirty_read(?MNESIA, {node(), App, Key}) of
                [] ->
                    case mnesia:dirty_read(?MNESIA, {App, Key}) of
                        [] ->
                            application:get_env(App, Key, Default);
                        [#vmq_config{val=GlobalVal}] ->
                            GlobalVal
                    end;
                [#vmq_config{val=NodeVal}] ->
                    NodeVal
            end,
            %% cache val
            ets:insert(?TABLE, {{App, Key}, Val}),
            application:set_env(App, Key, Val),
            Val
    end.

get_all_env(App) ->
    lists:foldl(fun({Key, Val}, Acc) ->
                        [{Key, get_env(App, Key, Val)}|Acc]
                end, [], application:get_all_env(App)).

set_env(Key, Val) ->
    set_env(vmq_server, Key, Val).
set_env(App, Key, Val) ->
    {atomic, ok} = mnesia:transaction(
      fun() ->
              Rec =
              case mnesia:read(?MNESIA, {node(), App, Key}) of
                  [] ->
                      #vmq_config{key={node(), App, Key},
                                  val=Val};
                  [#vmq_config{vclock=VClock} = C] ->
                      C#vmq_config{
                        val=Val,
                        vclock=unsplit_vclock:increment(node(), VClock)
                       }
              end,
              mnesia:write(Rec)
      end),
    ets:insert(?TABLE, {{App, Key}, Val}),
    ok.

configure_node() ->
    %% reset config
    ets:delete_all_objects(?TABLE),
    %% force cache initialization
    Configs = init_config_items(application:loaded_applications(), []),
    vmq_plugin:all(change_config, [Configs]).

init_config_items([{App, _, _}|Rest], Acc) ->
    case application:get_env(App, vmq_config_enabled, false) of
        true ->
            init_config_items(Rest, [{App, get_all_env(App)}|Acc]);
        false ->
            init_config_items(Rest, Acc)
    end;
init_config_items([], Acc) -> Acc.

-spec table_defs() -> [{atom(), [{atom(), any()}]}].
table_defs() ->
    [
     {vmq_config,
      [
       {record_name, vmq_config},
       {attributes, record_info(fields, vmq_config)},
       {disc_copies, [node()]},
       {match, #vmq_config{_='_'}},
       {user_properties,
        [{unsplit_method, {unsplit_lib, vclock, [vclock]}}]}
      ]}
    ].

%%% VMQ_SERVER CONFIG HOOK
change_config(Configs) ->
    {vmq_server, VmqServerConfig} = lists:keyfind(vmq_server, 1, Configs),
    Env = filter_out_unchanged(VmqServerConfig, []),
    %% change reg configurations
    case lists:keyfind(vmq_reg, 1, validate_reg_config(Env, [])) of
        {_, RegConfigs} when length(RegConfigs) > 0 ->
            vmq_reg_sup:reconfigure_registry(RegConfigs);
        _ ->
            ok
    end,
    %% change session configurations
    case lists:keyfind(vmq_session, 1, validate_session_config(Env, [])) of
        {_, SessionConfigs} when length(SessionConfigs) > 0 ->
            vmq_session_sup:reconfigure_sessions(SessionConfigs);
        _ ->
            ok
    end,
    case lists:keyfind(vmq_expirer, 1, validate_expirer_config(Env, [])) of
        {_, [{persistent_client_expiration, Duration}]} ->
            vmq_session_expirer:change_duration(Duration);
        _ ->
            ok
    end,
    case lists:keyfind(vmq_listener, 1, validate_listener_config(Env, [])) of
        {_, ListenerConfigs} when length(ListenerConfigs) > 0 ->
            vmq_tcp_listener_sup:reconfigure_listeners(ListenerConfigs);
        _ ->
            ok
    end.

filter_out_unchanged([{Key, Val} = Item|Rest], Acc) ->
    case gen_server:call(?MODULE, {last_val, Key, Val}) of
        Val ->
            filter_out_unchanged(Rest, Acc);
        _ ->
            filter_out_unchanged(Rest, [Item|Acc])
    end;
filter_out_unchanged([], Acc) -> Acc.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    ets:new(?TABLE, [public, named_table, {read_concurrency, true}]),
    vmq_plugin_mgr:enable_module_plugin(?MODULE, change_config, 1),
    {ok, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({last_val, Key, Val}, _From, LastVals) ->
    case lists:keyfind(Key, 1, LastVals) of
        false ->
            {reply, nil, [{Key, Val}|LastVals]};
        {Key, Val} ->
            %% unchanged
            {reply, Val, LastVals};
        {Key, OldVal} ->
            {reply, OldVal, [{Key, Val}|lists:keydelete(Key, 1, LastVals)]}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
validate_reg_config([{reg_views, Val} = Item|Rest], Acc)
  when is_list(Val) ->
    case length([RV || RV <- Val, is_atom(RV)]) == length(Val) of
        true ->
            validate_reg_config(Rest, [Item|Acc]);
        false ->
            validate_reg_config(Rest, Acc)
    end;
validate_reg_config([_|Rest], Acc) ->
    validate_reg_config(Rest, Acc);
validate_reg_config([], Acc) -> [{vmq_reg, Acc}].

validate_session_config([{allow_anonymous, Val} = Item|Rest], Acc)
  when is_boolean(Val) ->
    validate_session_config(Rest, [Item|Acc]);
validate_session_config([{max_client_id_size, Val} = Item|Rest], Acc)
  when is_integer(Val) and Val >= 0 ->
    validate_session_config(Rest, [Item|Acc]);
validate_session_config([{retry_interval, Val} = Item|Rest], Acc)
  when is_integer(Val) and Val > 0 ->
    validate_session_config(Rest, [Item|Acc]);
validate_session_config([{max_inflight_messages, Val} = Item|Rest], Acc)
  when is_integer(Val) and Val >= 0 ->
    validate_session_config(Rest, [Item|Acc]);
validate_session_config([{message_size_limit, Val} = Item|Rest], Acc)
  when is_integer(Val) and Val >= 0 ->
    validate_session_config(Rest, [Item|Acc]);
validate_session_config([{upgrade_outgoing_qos, Val} = Item|Rest], Acc)
  when is_boolean(Val) ->
    validate_session_config(Rest, [Item|Acc]);
validate_session_config([{trade_consistency, Val} = Item|Rest], Acc)
  when is_boolean(Val) ->
    validate_session_config(Rest, [Item|Acc]);
validate_session_config([{allow_multiple_sessions, Val} = Item|Rest], Acc)
  when is_boolean(Val) ->
    validate_session_config(Rest, [Item|Acc]);
validate_session_config([{default_reg_view, Val} = Item|Rest], Acc)
  when is_atom(Val) ->
    case code:is_loaded(Val) of
        {file, _} ->
            validate_session_config(Rest, [Item|Acc]);
        false ->
            lager:error("can't configure new default_reg_view ~p", [Val]),
            validate_session_config(Rest, Acc)
    end;
validate_session_config([_|Rest], Acc) ->
    validate_session_config(Rest, Acc);
validate_session_config([], []) -> [];
validate_session_config([], Acc) -> [{vmq_session, Acc}].

validate_expirer_config([{persistent_client_expiration, Val} = Item|Rest], Acc)
  when is_integer(Val) and Val >= 0 ->
    validate_expirer_config(Rest, [Item|Acc]);
validate_expirer_config([_|Rest], Acc) ->
    validate_expirer_config(Rest, Acc);
validate_expirer_config([], []) -> [];
validate_expirer_config([], Acc) -> [{vmq_expirer, Acc}].

validate_listener_config([{listeners, _} = Item|Rest], Acc) ->
    validate_listener_config(Rest, [Item|Acc]);
validate_listener_config([{tcp_listen_options, _} = Item|Rest], Acc) ->
    validate_listener_config(Rest, [Item|Acc]);
validate_listener_config([_|Rest], Acc) ->
    validate_listener_config(Rest, Acc);
validate_listener_config([], Acc) -> [{vmq_listener, Acc}].

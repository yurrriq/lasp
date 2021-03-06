%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Christopher Meiklejohn.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(lasp_config).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-export([dispatch/0, web_config/0]).

dispatch() ->
    lists:flatten([
        {["api", "plots"],      lasp_plots_resource,        undefined},
        {["api", "logs"],       lasp_logs_resource,         undefined},
        {["api", "health"],     lasp_health_check_resource, undefined},
        {["api", "status"],     lasp_status_resource,       undefined},
        {["api", "simulate"],   lasp_simulate_resource,     undefined},
        {[],                    lasp_gui_resource,          index},
        {['*'],                 lasp_gui_resource,          undefined}
    ]).

web_config() ->
    {ok, App} = application:get_application(?MODULE),
    {ok, Ip} = application:get_env(App, web_ip),
    DCOS = os:getenv("DCOS", "false"),
    Port = case DCOS of
              "false" ->
                DefaultPort = application:get_env(App, web_port, 8080),
                list_to_integer(os:getenv("WEB_PORT", integer_to_list(DefaultPort)));
              _ ->
                80
          end,
    lager:info("Port override: ~p", [Port]),
    [
        {ip, Ip},
        {port, Port},
        {log_dir, "priv/log"},
        {dispatch, dispatch()}
    ].

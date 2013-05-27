%% Copyright (c) 2011-2012 Basho Technologies, Inc.  All Rights Reserved.
%% Copyright (c) 2013 LeChat, Inc.  All Rights Reserved.
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

%% @doc Syslog backend for lager.

-module(lager_syslogerl_backend).

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-export([config_to_id/1]).

-record(state, {level, handle, id, formatter, format_config}).

-include_lib("lager/include/lager.hrl").

-define(DEFAULT_FORMAT,["[", severity, "] ",
        {pid, ""},
        {module, [
                {pid, ["@"], ""},
                module,
                {function, [":", function], ""},
                {line, [":",line], ""}], ""},
        " ", message]).


%% @private
init([Ident, Facility, Level]) when is_atom(Level) ->
    init([Ident, Facility, Level, {lager_default_formatter, ?DEFAULT_FORMAT}]);
init([Ident, Facility, Level, {Formatter, FormatterConfig}]) when is_atom(Level), is_atom(Formatter) ->
    case application:start(syslogerl) of
        ok ->
            init2([Ident, Facility, Level, {Formatter, FormatterConfig}]);
        {error, {already_started, _}} ->
            init2([Ident, Facility, Level, {Formatter, FormatterConfig}]);
        Error ->
            Error
    end.

%% @private
init2([Ident, Facility, Level, {Formatter, FormatterConfig}]) ->
    {ok, Pid} = syslogerl:start_link(),
    try parse_level(Level) of
        Level0 ->
            {ok, #state{
                level=Level0,
                id=config_to_id([Ident, Facility, Level]),
                handle=Pid,
                formatter=Formatter,
                format_config=FormatterConfig
            }}
    catch
        _:_ ->
            {error, bad_log_level}
    end.

%% @private
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    try parse_level(Level) of
        Lvl ->
            {ok, ok, State#state{level=Lvl}}
    catch
        _:_ ->
            {ok, {error, bad_log_level}, State}
    end;
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Level, {_Date, _Time}, [_LevelStr, _Location, Message]},
 #state{level = LogLevel, formatter = Formatter, format_config = FormatConfig, id = {_, {Ident, Facility}}} = State) when Level =< LogLevel ->
    FacilityNumber = syslogerl:facility_to_number(Facility),
    Severity = syslogerl:severity_to_number(lager_msg:severity(Message)),
    MessageText = iolist_to_binary(Formatter:format(Message, FormatConfig)),
    syslogerl:send(FacilityNumber, Ident, Severity, MessageText),
    {ok, State};

handle_event({log, Message},
  State = #state{level = Level, formatter = Formatter, format_config = FormatConfig, id = {_, {Ident, Facility}}} = State) ->
    case lager_util:is_loggable(Message, Level, State#state.id) of
        true ->
            FacilityNumber = syslogerl:facility_to_number(Facility),
            Severity = syslogerl:severity_to_number(lager_msg:severity(Message)),
            MessageText = iolist_to_binary(Formatter:format(Message, FormatConfig)),
            syslogerl:send(FacilityNumber, Ident, Severity, MessageText),
            {ok, State};
        false ->
            {ok, State}
    end;
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% convert the configuration into a hopefully unique gen_event ID
config_to_id([Ident, Facility, _Level]) ->
    {?MODULE, {Ident, Facility}};
config_to_id([Ident, Facility, _Level, _Formatter]) ->
    {?MODULE, {Ident, Facility}}.

parse_level(Level) ->
    try lager_util:config_to_mask(Level) of
        Res ->
            Res
    catch
        error:undef ->
            %% must be lager < 2.0
            lager_util:level_to_num(Level)
    end.

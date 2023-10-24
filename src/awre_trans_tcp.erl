%%
%% Copyright (c) 2015 Bas Wegh
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%


-module(awre_trans_tcp).
-behaviour(awre_transport).
-include_lib("kernel/include/logger.hrl").

-define(RAW_PING_PREFIX, 1). % <<0:5, 1:3>>
-define(RAW_PONG_PREFIX, 2). % <<0:5, 2:3>>

-export([init/1]).
-export([send_to_router/2]).
-export([handle_info/2]).
-export([shutdown/1]).

-record(state,{
    awre_con = unknown,
    socket = none,
    enc = unknown,
    sernum = unknown,
    realm = none,
    version = unknown,
    client_details = unknown,
    buffer = <<"">>,
    out_max = unknown,
    handshake = in_progress
}).


init(#{realm := Realm, awre_con := Con, client_details := CDetails, version := Version,
    host := Host, port := Port, enc := Encoding}) ->
  Family = case application:get_env(awre, ip_version, 4) of
    6 ->
      inet6;
    _ ->
      %% 4 or invalid value
      inet
  end,
  {ok, Socket} = gen_tcp:connect(Host,Port,[binary,{packet,0}, Family], 5000),
  link(Socket),
  % need to send the new TCP packet
  Enc = case Encoding of
          json -> raw_json;
          raw_json -> raw_json;
          msgpack -> raw_msgpack;
          raw_msgpack -> raw_msgpack;
          erlbin -> raw_erlbin;
          raw_erlbin -> raw_erlbin;
          _ -> raw_msgpack
        end,
  SerNum = case Enc of
             raw_json -> 1;
             raw_msgpack -> 2;
             raw_erlbin ->
               EBinNumber = application:get_env(awre,erlbin_number,undefined),
               case {is_integer(EBinNumber), EBinNumber > 0} of
                 {true,true} -> EBinNumber;
                 _ -> error("application parameter erlbin_number not set")
               end;
             _ -> 0
           end,
  MaxLen = 15,
  ok = gen_tcp:send(Socket,<<127,MaxLen:4,SerNum:4,0,0>>),
    State = #state{
        awre_con = Con,
        version = Version,
        client_details = CDetails,
        socket = Socket,
        enc = Enc,
        sernum = SerNum,
        realm = Realm
    },
    {ok, State}.


send_to_router({ping, Payload}, #state{socket= S} = State) ->
    Frame = <<(?RAW_PING_PREFIX):8, (byte_size(Payload)):24, Payload/binary>>,
    ok = gen_tcp:send(S, Frame),
    {ok, State};

send_to_router({pong, Payload}, #state{socket= S} = State) ->
    Frame = <<(?RAW_PONG_PREFIX):8, (byte_size(Payload)):24, Payload/binary>>,
    ok = gen_tcp:send(S, Frame),
    {ok, State};

send_to_router(Message,#state{socket=S, enc=Enc, out_max=MaxLength} = State) ->
  SerMessage = wamper_protocol:serialize(Message,Enc),
  case byte_size(SerMessage) > MaxLength of
    true ->
      ok;
    false ->
      ok = gen_tcp:send(S,SerMessage)
  end,
  {ok,State}.

handle_info({tcp,Socket,Data},#state{buffer=Buffer,socket=Socket,enc=Enc, handshake=done}=State) ->
  {Messages,NewBuffer} = wamper_protocol:deserialize(<<Buffer/binary, Data/binary>>,Enc),
  forward_messages(Messages,State),
  {ok,State#state{buffer=NewBuffer}};
handle_info({tcp,Socket,<<127,0,0,0>>},#state{socket=Socket}=State) ->
  forward_messages([{abort,#{},tcp_handshake_failed}],State),
  {ok,State};
handle_info({tcp,Socket,<<127,L:4,S:4,0,0>>},
            #state{socket=Socket,realm=Realm,sernum=SerNum, version=Version, client_details=CDetails}=State) ->
  S = SerNum,
  State1 = State#state{out_max=math:pow(2,9+L), handshake=done},
  send_to_router({hello,Realm,#{agent=>Version, roles => CDetails}},State1);
handle_info({tcp_closed, Socket}, State) ->
    ?LOG_INFO(#{
      text => "Connection closed",
      reason => tcp_closed,
      socket => Socket
    }),
    {stop, tcp_closed, State};

handle_info({tcp_error, Socket, Reason}, State) ->
    ?LOG_INFO(#{
        text => "Connection closed",
        socket => Socket,
        reason => Reason
    }),
    {stop, Reason, State};

handle_info(Info, State) ->
    ?LOG_ERROR(#{
      text => "Received unknown info message",
      message => Info
    }),
	{noreply, State}.


shutdown(#state{socket=S}) ->
  ok = gen_tcp:close(S),
  ok.



forward_messages([], _) ->
  ok;

forward_messages([{ping, Payload}|Tail], State0) ->
  {ok, State1} = send_to_router({pong, Payload}, State0),
  forward_messages(Tail, State1);

forward_messages([Msg|Tail],#state{awre_con=Con}=State) ->
  awre_con:send_to_client(Msg,Con),
  forward_messages(Tail, State).





%% =============================================================================
%% PRIVATE
%% =============================================================================

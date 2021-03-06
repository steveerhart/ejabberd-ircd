-module(ejabberd_ircd).
-author('henoch@dtek.chalmers.se').
-update_info({update, 0}).

-behaviour(gen_fsm).

%% External exports
-export([start/2,
	 start_link/2,
	 socket_type/0]).

%% gen_fsm callbacks
-export([init/1,
	 wait_for_login/2,
	 wait_for_cmd/2,
	 handle_event/3,
	 handle_sync_event/4,
	 code_change/4,
	 handle_info/3,
	 terminate/3
	]).

%-define(ejabberd_debug, true).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(DICT, dict).

-record(state, {socket,
		sockmod,
		access,
		encoding,
		shaper,
		webirc,
		host,
		muc_host,
		sid = none,
		pass = "",
		% this is the nickname seen in the channels 
		nick = none,
		% this is the username used for generating the jabber ID 
		% this is initially the same as the Nickname seen in the channels
		jidnick = none,
		user = none,
		realname = none,
		%% joining is a mapping from room JIDs to nicknames
		%% received but not yet forwarded
		joining = ?DICT:new(),
		joined = ?DICT:new(),
		%% mapping certain channels to certain rooms
		channels_to_jids = ?DICT:new(),
		jids_to_channels = ?DICT:new(),
		%% maps /iq/@id to {ReplyFun/1, expire timestamp
		outgoing_requests = ?DICT:new()
	       }).
-record(channel, {participants = [],
		  topic = ""}).

-record(line, {prefix, command, params}).

%-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(SockData, Opts) ->
    supervisor:start_child(ejabberd_ircd_sup, [SockData, Opts]).

start_link(SockData, Opts) ->
    gen_fsm:start_link(ejabberd_ircd, [SockData, Opts], ?FSMOPTS).

socket_type() ->
    raw.

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%%----------------------------------------------------------------------
init([{SockMod, Socket}, Opts]) ->
    iconv:start(),
    Access = case lists:keysearch(access, 1, Opts) of
		 {value, {_, A}} -> A;
		 _ -> all
	     end,
    Shaper = case lists:keysearch(shaper, 1, Opts) of
		 {value, {_, S}} -> S;
		 _ -> none
	     end,
    WebIrc = case lists:keysearch(webirc, 1, Opts) of
	       {value, {_, W}} -> W;
	       _ -> none
	   end,
    Host = case lists:keysearch(host, 1, Opts) of
	       {value, {_, H}} -> H;
	       _ -> ?MYNAME
	   end,
    MucHost = case lists:keysearch(muc_host, 1, Opts) of
		  {value, {_, M}} -> M;
		  _ -> "conference." ++ ?MYNAME
	      end,
    Encoding = case lists:keysearch(encoding, 1, Opts) of
		   {value, {_, E}} -> E;
		   _ -> "utf-8"
	       end,
    ChannelMappings = case lists:keysearch(mappings, 1, Opts) of
			  {value, {_, C}} -> C;
			  _ -> []
		      end,
    {ChannelToJid, JidToChannel} =
	lists:foldl(fun({Channel, Room}, {CToJ, JToC}) ->
			    RoomJID = jlib:string_to_jid(Room),
			    BareChannel = case Channel of
					      [$#|R] -> R;
					      _ -> Channel
					  end,
			    {?DICT:store(BareChannel, RoomJID, CToJ),
			     ?DICT:store(RoomJID, BareChannel, JToC)}
		    end, {?DICT:new(), ?DICT:new()},
		    ChannelMappings),
    inet:setopts(Socket, [list, {packet, line}, {active, true}]),
    %%_ReceiverPid = start_ircd_receiver(Socket, SockMod),
    {ok, wait_for_login, #state{socket    = Socket,
			       sockmod   = SockMod,
			       access    = Access,
			       encoding  = Encoding,
			       shaper    = Shaper,
			       webirc    = WebIrc,
			       host      = Host,
			       muc_host  = MucHost,
			       channels_to_jids = ChannelToJid,
			       jids_to_channels = JidToChannel
			      }}.

handle_info({tcp, _Socket, Line}, StateName, StateData) ->
    DecodedLine = iconv:convert(StateData#state.encoding, "utf-8", Line),
    Parsed = parse_line(DecodedLine),
    ?MODULE:StateName({line, Parsed}, StateData);
handle_info({tcp_closed, _}, _StateName, StateData) ->
    {stop, normal, StateData};
handle_info({route, _, _, _} = Event, StateName, StateData) ->
    ?MODULE:StateName(Event, StateData);
handle_info(Info, StateName, StateData) ->
    ?ERROR_MSG("Unexpected info: ~p", [Info]),
    {next_state, StateName, StateData}.

handle_sync_event(Event, _From, StateName, StateData) ->
    ?ERROR_MSG("Unexpected sync event: ~p", [Event]),
    Reply = ok,
    {reply, Reply, StateName, StateData}.

handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.
terminate(_Reason, _StateName, #state{socket = Socket, sockmod = SockMod,
				      sid = SID, nick = Nick,
				      joined = JoinedDict} = State) ->
    ?INFO_MSG("closing IRC connection for ~p", [Nick]),
    case SID of
	none ->
	    ok;
	_ ->
	    Packet = {xmlelement, "presence",
		      [{"type", "unavailable"}], []},
	    FromJID = user_jid(State),
	    ?DICT:map(fun(ChannelJID, _ChannelData) ->
			      ejabberd_router:route(FromJID, ChannelJID, Packet)
		      end, JoinedDict),
	    ejabberd_sm:close_session_unset_presence(SID, FromJID#jid.user,
						     FromJID#jid.server, FromJID#jid.resource,
						     "Logged out")
    end,
    gen_tcp = SockMod,
    ok = gen_tcp:close(Socket),
    ok.


wait_for_login({line, #line{command = "WEBIRC", params = [Password, _, _, _]}}, State) ->
    ?DEBUG("in wait_for_login", []),
    ?DEBUG("got webirc pass ~p", [Password]),
    if
	Password==State#state.webirc -> 
		{next_state, wait_for_login, State};
	true -> 
    		send_reply('ERR_NOTONCHANNEL', ["You're not on that channel"], State),
		{stop, normal, State}
    end;
wait_for_login({line, #line{command = "PASS", params = [Pass | _]}}, State) ->
    {next_state, wait_for_login, State#state{pass = Pass}};

wait_for_login({line, #line{command = "NICK", params = [Nick | _]}}, State) ->
    wait_for_login(info_available, State#state{nick = Nick});

wait_for_login({line, #line{command = "USER", params = [User, _Host, _Server, Realname]}}, State) ->
    wait_for_login(info_available, State#state{user = User,
					       realname = Realname});
wait_for_login(info_available, #state{host = Server,
				      nick = Nick,
				      pass = Pass,
				      user = User,
				      realname = Realname} = State)
  when Nick =/= none andalso
       User =/= none andalso
       Realname =/= none ->
    JID = user_jid(State),
    case JID of
	error ->
	    ?DEBUG("invalid nick '~p'", [Nick]),
	    send_reply('ERR_ERRONEUSNICKNAME', [Nick, "Erroneous nickname"], State),
	    {next_state, wait_for_login, State};
	_ ->
	    case acl:match_rule(Server, State#state.access, JID) of
		deny ->
		    ?DEBUG("access denied for '~p'", [Nick]),
		    send_reply('ERR_NICKCOLLISION', [Nick, "Nickname collision"], State),
		    {next_state, wait_for_login, State};
		allow ->
		    case ejabberd_auth:check_password(Nick, Server, Pass) of
			false ->
			    ?DEBUG("auth failed for '~p'", [Nick]),
			    send_reply('ERR_NICKCOLLISION', [Nick, "Authentication failed"], State),
			    {next_state, wait_for_login, State};
			true ->
			    ?DEBUG("good nickname '~p'", [Nick]),
			    SID = {now(), self()},
			    Info = [{ip, peerip(gen_tcp, State#state.socket)}, {conn, irc}],
			    ejabberd_sm:open_session(
			      SID, JID#jid.user, JID#jid.server, JID#jid.resource, Info),
			    send_text_command("", "001", [Nick, "IRC interface of ejabberd server "++Server], State),
			    send_reply('RPL_MOTDSTART', [Nick, "- "++Server++" Message of the day - "], State),
			    send_reply('RPL_MOTD', [Nick, "- This is the IRC interface of the ejabberd server "++Server++"."], State),
			    send_reply('RPL_MOTD', [Nick, "- Your full JID is "++Nick++"@"++Server++"/irc."], State),
			    send_reply('RPL_MOTD', [Nick, "- Channel #whatever corresponds to MUC room whatever@"++State#state.muc_host++"."], State),
			    send_reply('RPL_MOTD', [Nick, "- This IRC interface is quite immature.  You will probably find bugs."], State),
			    send_reply('RPL_MOTD', [Nick, "- Have a good time!"], State),
			    send_reply('RPL_ENDOFMOTD', [Nick, "End of /MOTD command"], State),
			    {next_state, wait_for_cmd, State#state{nick = Nick, jidnick = Nick, sid = SID, pass = ""}}
		    end
	    end
    end;
wait_for_login(info_available, State) ->
    %% Ignore if either NICK or USER is pending
    {next_state, wait_for_login, State};

wait_for_login(Event, State) ->
    ?DEBUG("in wait_for_login", []),
    ?INFO_MSG("unexpected event ~p", [Event]),
    {next_state, wait_for_login, State}.

peerip(SockMod, Socket) ->
    IP = case SockMod of
	     gen_tcp -> inet:peername(Socket);
	     _ -> SockMod:peername(Socket)
	 end,
    case IP of
	{ok, IPOK} -> IPOK;
	_ -> undefined
    end.

wait_for_cmd({line, #line{command = "USER", params = [_Username, _Hostname, _Servername, _Realname]}}, State) ->
    %% Yeah, like we care.
    {next_state, wait_for_cmd, State};
wait_for_cmd({line, #line{command = "JOIN", params = Params}}, State) ->
    {ChannelsString, KeysString} =
	case Params of
	    [C, K] ->
		{C, K};
	    [C] ->
		{C, []}
	end,
    Channels = string:tokens(ChannelsString, ","),
    Keys = string:tokens(KeysString, ","),
    NewState = join_channels(Channels, Keys, State),
    {next_state, wait_for_cmd, NewState};

wait_for_cmd({line, #line{command = "NAMES", params = [ChannelsString]}}, State) ->
    ?DEBUG("in wait_for_cmd NAMES ~p", [ChannelsString]),
    reply_names(string:tokens(ChannelsString, ","), State),
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "NICK", params = [NewNick]}}, State) ->
    Nick = State#state.nick,
    ?DEBUG("in wait_for_cmd ~p changes nick to ~p", [Nick, NewNick]),
    case NewNick of
	Nick -> ""; 
	_ ->
    		send_text_command(Nick, "NICK", [NewNick], State),
    		?DICT:fold(
			fun(Channel, _, AccIn) -> Packet =
				{xmlelement, "presence", [],
		   			[{xmlelement, "priority", [], [1]}]
				}, 
				From=user_jid(State),
				To=jlib:jid_replace_resource(Channel, NewNick),
    				ejabberd_router:route(From, To, Packet),
				AccIn
			end, "", State#state.joined)
	end,
    {next_state, wait_for_cmd, State#state{nick=NewNick}};

wait_for_cmd({line, #line{command = "PART", params = [ChannelsString | MaybeMessage]}}, State) ->
    Message = case MaybeMessage of
		  [] -> nothing;
		  [M] -> M
	      end,
    Channels = string:tokens(ChannelsString, ","),
    	lists:foreach(
		fun(Channel) ->
			% generates something like nick!nick@#chatroom
    			IRCSender = make_irc_sender(State#state.nick, channel_to_jid(Channel, State), State),
	   		send_command(IRCSender, "PART", [Channel], State)
		end, Channels
	),
    NewState = part_channels(Channels, State, Message),
    {next_state, wait_for_cmd, NewState};

wait_for_cmd({line, #line{command = "PRIVMSG", params = [To, Text]}}, State) ->
    Recipients = string:tokens(To, ","),
    FromJID = user_jid(State),
    lists:foreach(
      fun(Rcpt) ->
	      case Rcpt of
		  [$# | Roomname] ->
		      Packet = {xmlelement, "message",
				[{"type", "groupchat"}],
				[{xmlelement, "body", [],
				  filter_cdata(translate_action(Text))}]},
		      ToJID = channel_to_jid(Roomname, State),
		      ejabberd_router:route(FromJID, ToJID, Packet);
		  _ ->
		      case string:tokens(Rcpt, "#") of
			  [Nick, Channel] ->
			      Packet = {xmlelement, "message",
					[{"type", "chat"}],
					[{xmlelement, "body", [],
					  filter_cdata(translate_action(Text))}]},
			      ToJID = channel_nick_to_jid(Nick, Channel, State),
			      ejabberd_router:route(FromJID, ToJID, Packet);
			  _ ->
			      send_text_command(Rcpt, "NOTICE", [State#state.nick,
								 "Your message to "++
								 Rcpt++
								 " was dropped.  "
								 "Try sending it to "++Rcpt++
								 "#somechannel."], State)
		      end
	      end
      end, Recipients),
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "PING", params = Params}}, State) ->
    {Token, Whom} =
	case Params of
	    [A] ->
		{A, ""};
	    [A, B] ->
		{A, B}
	end,
    if Whom == ""; Whom == State#state.host ->
	    %% Ping to us
	    send_command("", "PONG", [State#state.host, Token], State);
       true ->
	    %% Ping to someone else
	    ?DEBUG("ignoring ping to ~s", [Whom]),
	    ok
    end,
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "TOPIC", params = Params}}, State) ->
    case Params of
	[Channel] ->
	    %% user asks for topic
	    case ?DICT:find(channel_to_jid(Channel, State),
			    State#state.joined) of
		{ok, #channel{topic = Topic}} ->
		    case Topic of
			"" ->
			    send_reply('RPL_NOTOPIC', ["No topic is set"], State);
			_ ->
			    send_reply('RPL_TOPIC', [Topic], State)
		    end;
		_ ->
		    send_reply('ERR_NOTONCHANNEL', ["You're not on that channel"], State)
	    end;
	[Channel, NewTopic] ->
	    Packet =
		{xmlelement, "message",
		 [{"type", "groupchat"}],
		 [{xmlelement, "subject", [], filter_cdata(NewTopic)}]},
	    FromJID = user_jid(State),
	    ToJID = channel_to_jid(Channel, State),
	    ejabberd_router:route(FromJID, ToJID, Packet)
    end,
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "MODE", params = [ModeOf | Params]}}, State) ->
    case ModeOf of
	[$# | Channel] ->
	    ChannelJid = channel_to_jid(Channel, State),
	    Joined = ?DICT:find(ChannelJid, State#state.joined),
	    case Joined of
		{ok, _ChannelData} ->
		    case Params of
			[] ->
			    %% This is where we could mirror some advanced MUC
			    %% properties.
			    %%send_reply('RPL_CHANNELMODEIS', [Channel, Modes], State);
			    send_reply('ERR_NOCHANMODES', [Channel], State);
			["b"] ->
			    send_reply('RPL_ENDOFBANLIST', [Channel, "Ban list not available"], State);
			_ ->
			    send_reply('ERR_UNKNOWNCOMMAND', ["MODE", io_lib:format("MODE ~p not understood", [Params])], State)
		    end;
		_ ->
		    send_reply('ERR_NOTONCHANNEL', [Channel, "You're not on that channel"], State)
	    end;
	Nick ->
	    if Nick == State#state.nick ->
		    case Params of
			[] ->
			    send_reply('RPL_UMODEIS', [], State);
			[Flags|_] ->
			    send_reply('ERR_UMODEUNKNOWNFLAG', [Flags, "No MODE flags supported"], State)
		    end;
	       true ->
		    send_reply('ERR_USERSDONTMATCH', ["Can't change mode for other users"], State)
	    end
    end,
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "LIST"}}, #state{nick = Nick} = State) ->
    Id = randoms:get_string(),
    ejabberd_router:route(user_jid(State), jlib:make_jid("", State#state.muc_host, ""),
			  {xmlelement, "iq", [{"type", "get"},
					      {"id", Id}],
			   [{xmlelement, "query",
			     [{"xmlns", ?NS_DISCO_ITEMS}], []}
			   ]}),
    F = fun(Reply, State2) ->
		Type = xml:get_tag_attr_s("type", Reply),
		Xmlns = xml:get_path_s(Reply, [{elem, "query"}, {attr, "xmlns"}]),
		case {Type, Xmlns} of
		    {"result", ?NS_DISCO_ITEMS} ->
			{xmlelement, _, _, Items} = xml:get_subtag(Reply, "query"),
			send_reply('RPL_LISTSTART', [Nick, "N Title"], State2),
			lists:foreach(fun({xmlelement, "item", _, _} = El) ->
					      case {xml:get_tag_attr("jid", El),
						    xml:get_tag_attr("name", El)} of
						  {{value, JID}, false} ->
						      Channel = jid_to_channel(jlib:string_to_jid(JID), State2),
						      send_reply('RPL_LIST', [Nick, Channel, "0", ""], State2);
						  {{value, JID}, {value, Name}} ->
						      Channel = jid_to_channel(jlib:string_to_jid(JID), State2),
						      %% TODO: iconv(Name)
						      send_reply('RPL_LIST', [Nick, Channel, "0", Name], State2);
						  _ -> ok
					      end
				      end, Items),
    			lists:foreach(
    				fun(Channel) ->
    					send_reply('RPL_LIST', [State#state.nick, "#"++Channel], State)
    				end, ?DICT:fetch_keys(State#state.channels_to_jids)),
			send_reply('RPL_LISTEND', [Nick, "End of discovery result"], State2);
		    _ ->
			send_reply('ERR_NOSUCHSERVER', ["Invalid response"], State2)
		end,
		{next_state, wait_for_cmd, State2}
	end,
    NewState = State#state{outgoing_requests = ?DICT:append(Id, F, State#state.outgoing_requests)},
    {next_state, wait_for_cmd, NewState};

wait_for_cmd({line, #line{command = "QUIT"}}, State) ->
    %% quit message is ignored for now
    {stop, normal, State};

wait_for_cmd({line, #line{command = Unknown, params = Params} = Line}, State) ->
    ?INFO_MSG("Unknown command: ~p", [Line]),
    send_reply('ERR_UNKNOWNCOMMAND', [Unknown, "Unknown command or arity: " ++
				      Unknown ++ "/" ++ integer_to_list(length(Params))], State),
    {next_state, wait_for_cmd, State};

wait_for_cmd({route, From, _To, {xmlelement, "presence", Attrs, Els} = El}, State) ->
    % type can get "error"  or ""
    Type = xml:get_attr_s("type", Attrs),
    % FromRoom is chatroom@conference.example.net as jabber id
    FromRoom = jlib:jid_remove_resource(From),
    % The Nickname 
    FromNick = From#jid.resource,
    
    % returns the channel "#chatrom"
    Channel = jid_to_channel(From, State),
    % this is my current nick or the one I want to have
    MyNick = State#state.nick,
    % generates something like nick!nick@#chatroom
    IRCSender = make_irc_sender(FromNick, FromRoom, State),

    % some debug code
    %send_reply('RPL_MOTD', [MyNick, "Got Presence "++FromNick++"."], State),

    % make a dict find for the channel in state joining 
    Joining = ?DICT:find(FromRoom, State#state.joining),
    % and in state joined
    Joined = ?DICT:find(FromRoom, State#state.joined),
    case {Joining, Joined, Type} of
	{{ok, ChannelData}, _, ""} ->
	   BufferedNicks=ChannelData#channel.participants,
	    case BufferedNicks of
		[] ->
		    %% If this is the first presence, tell the
		    %% client that it's joining.
		    send_command(make_irc_sender(MyNick, FromRoom, State),
				 "JOIN", [Channel], State);
		_ ->
		    ok
	    end,
	    
	    % NewRole enthält /presence/x/item@role but sometimes ""
	    NewRole = case find_el("x", ?NS_MUC_USER, Els) of
			  nothing ->
			      "";
			  XMucEl ->
			      xml:get_path_s(XMucEl, [{elem, "item"}, {attr, "role"}])
		      end,
	    
	    %attach the user with the role to our BufferedNicks list
	    % but only if the presence has a role 
	    NewBufferedNicks = case NewRole of 
		"" -> BufferedNicks;
		_ -> [{FromNick, NewRole} | BufferedNicks]
	    end,
	    ?DEBUG("~s is present in ~s.  we now have ~p.",
		   		[FromNick, Channel, NewBufferedNicks]),
	    %% We receive our own presence last.  XXX: there
	    %% are some status codes here.  See XEP-0045,
	    %% section 7.1.3.
	    NewState =
		case {FromNick, NewRole} of
		    % this is a presence without a role we have to do nothing yet 
		   {MyNick, ""} -> State;
		    {MyNick, _} ->
			NewJoiningDict = ?DICT:erase(FromRoom, State#state.joining),
			NewChannelData = #channel{participants = NewBufferedNicks},
			NewJoinedDict = ?DICT:store(FromRoom, NewChannelData, State#state.joined),
			MyState=State#state{joining = NewJoiningDict,
                                    joined = NewJoinedDict},
		        reply_names(Channel, NewChannelData, MyState),
			MyState;
		    {_, _} ->
			% there iss a nick joining a channel, or a nick who is present in a channel 
                        % we have to make an entry  
			NewJoining = ?DICT:store(FromRoom, #channel{participants = NewBufferedNicks}, State#state.joining),
			State#state{joining = NewJoining}
		end,
	    {next_state, wait_for_cmd, NewState};
	{{ok, _ChannelData}, _, "error"} ->
	   %BufferedNicks=ChannelData#channel.participants,
	    NewState =
		case FromNick of
		    MyNick ->
    			send_reply('RPL_MOTD', [MyNick, "Error reply "++FromRoom++" "++FromNick++" "], State),
			%% we couldn't join the room
			{ReplyCode, ErrorDescription} =
			    case xml:get_subtag(El, "error") of
				{xmlelement, _, _, _} = ErrorEl ->
				    {ErrorName, ErrorText} = parse_error(ErrorEl),
				    {case ErrorName of
					 "forbidden" -> 'ERR_INVITEONLYCHAN';
					 _ -> 'ERR_NOSUCHCHANNEL'
				     end,
				     if is_list(ErrorText) ->
					     ErrorName ++ ": " ++ ErrorText;
					true ->
					     ErrorName
				     end};
				_ ->
				    {'ERR_NOSUCHCHANNEL', "Unknown error"}
			    end,
			send_reply(ReplyCode, [Channel, ErrorDescription], State),

			NewJoiningDict = ?DICT:erase(FromRoom, State#state.joining),
			State#state{joining = NewJoiningDict};
		    _ ->
			?ERROR_MSG("ignoring presence of type ~s from ~s while joining room",
				   [Type, jlib:jid_to_string(From)]),
			State
		end,
	    {next_state, wait_for_cmd, NewState};
	%% Presence in a channel we have already joined
	% We have to build some new states here 
	{_, {ok, ChannelData}, ""} ->
	   BufferedNicks=ChannelData#channel.participants,
	    %% Someone enters
	    % make a NewBufferedNicks  
            % do not send JOIN if this is me
	    NewState=case FromNick of 
		MyNick ->
			State; 
		_ -> 
	    	      MyRole = case find_el("x", ?NS_MUC_USER, Els) of
			  nothing ->
			      "";
			  XMucEl ->
			      xml:get_path_s(XMucEl, [{elem, "item"}, {attr, "role"}])
		      	end,
			NewBufferedNicks=[{FromNick, MyRole}|BufferedNicks],
			NewJoinedDict = ?DICT:update(FromRoom, 
				fun(MyChannelData) ->
					MyChannelData#channel{participants=NewBufferedNicks}
				end,
			State#state.joined),
	    		send_command(IRCSender, "JOIN", [Channel], State),
			State#state{joined=NewJoinedDict}
		end,
	    {next_state, wait_for_cmd, NewState};
	{_, {ok, _}, "error"} ->
	    % Some error occured this is maybe a nickname collision
 	    NewState=case FromNick of 
		MyNick -> 
	   		send_command(IRCSender, "PART", [Channel], State),
			part_channels(Channel, State, "Nickname Collision");
		_ -> State
	    end,
	    {next_state, wait_for_cmd, NewState};
	{_, {ok, ChannelData}, "unavailable"} ->
	   BufferedNicks=ChannelData#channel.participants,
	    %% Someone leaves or we have a nick change 
	    % NewRole enthält /presence/x/item@role but sometimes ""
	   {NewNick, Status} = case find_el("x", ?NS_MUC_USER, Els) of
		  nothing ->
		      "";
		  XMucEl ->
		      {xml:get_path_s(XMucEl, [{elem, "item"}, {attr, "nick"}]),
		      xml:get_path_s(XMucEl, [{elem, "status"}, {attr, "code"}])}
	     	 end,
	    NewState=case {NewNick, Status} of
		{MyNick, "303"} -> % yes the nick was changed 
			NewBufferedNicks=update_nick_in_list(FromNick, NewNick, BufferedNicks),
			NewJoinedDict = ?DICT:update(FromRoom, 
				fun(MyChannelData) ->
					MyChannelData#channel{participants=NewBufferedNicks}
				end,
			State#state.joined),
			State#state{joined = NewJoinedDict};
		{_, _} ->
			% something else happened   
	   		send_command(IRCSender, "PART", [Channel], State),
			State
	   end,
	   {next_state, wait_for_cmd, NewState};
	{_, {ok, ChannelData}, _} ->
	   BufferedNicks=ChannelData#channel.participants,
	    %% in any other case Someone leaves, too 
	  NewBufferedNicks=remove_nick_from_list(FromNick, BufferedNicks),
	   NewJoinedDict = ?DICT:update(FromRoom, 
		fun(MyChannelData) ->
			MyChannelData#channel{participants=NewBufferedNicks}
		end,
	   State#state.joined),
	    send_command(IRCSender, "PART", [Channel], State),
	   {next_state, wait_for_cmd, State#state{joined = NewJoinedDict}};
	_ ->
	    %% to part channels with nickname collisions
	    ?INFO_MSG("unexpected presence from ~s", [jlib:jid_to_string(From)]),
	    {next_state, wait_for_cmd, State}
    end;

wait_for_cmd({route, From, _To, {xmlelement, "message", Attrs, Els} = El}, State) ->
    Type = xml:get_attr_s("type", Attrs),
    case Type of
	"groupchat" ->
	    ChannelJID = jlib:jid_remove_resource(From),
	    case ?DICT:find(ChannelJID, State#state.joined) of
		{ok, #channel{} = ChannelData} ->
		    FromChannel = jid_to_channel(From, State),
		    FromNick = From#jid.resource,
		    Subject = xml:get_path_s(El, [{elem, "subject"}, cdata]),
		    Body = xml:get_path_s(El, [{elem, "body"}, cdata]),
		    XDelay = lists:any(fun({xmlelement, "x", XAttrs, _}) ->
					       xml:get_attr_s("xmlns", XAttrs) == ?NS_DELAY;
					  (_) ->
					       false
				       end, Els),
		    if
			Subject /= "" ->
			    CleanSubject = lists:map(fun($\n) ->
							     $\ ;
							(C) -> C
						     end, Subject),
			    send_text_command(make_irc_sender(From, State),
					      "TOPIC", [FromChannel, CleanSubject], State),
			    NewChannelData = ChannelData#channel{topic = CleanSubject},
			    NewState = State#state{joined = ?DICT:store(jlib:jid_remove_resource(From), NewChannelData, State#state.joined)},
			    {next_state, wait_for_cmd, NewState};
			not XDelay, FromNick == State#state.nick ->
			    %% there is no message echo in IRC.
			    %% we let the backlog through, though.
			    {next_state, wait_for_cmd, State};
			true ->
			    BodyLines = string:tokens(Body, "\n"),
			    lists:foreach(
			      fun(Line) ->
				      Line1 =
					  case Line of
					      [$/, $m, $e, $  | Action] ->
						  [1]++"ACTION "++Action++[1];
					      _ ->
						  Line
					  end,
				      send_text_command(make_irc_sender(From, State),
							"PRIVMSG", [FromChannel, Line1], State)
			      end, BodyLines),
			    {next_state, wait_for_cmd, State}
		    end;
		error ->
		    ?ERROR_MSG("got message from ~s without having joined it",
			       [jlib:jid_to_string(ChannelJID)]),
		    {next_state, wait_for_cmd, State}
	    end;
	"error" ->
	    MucHost = State#state.muc_host,
	    ErrorFrom =
		case From of
		    #jid{lserver = MucHost,
			 luser = Room,
			 lresource = ""} ->
			[$#|Room];
		    #jid{lserver = MucHost,
			 luser = Room,
			 lresource = Nick} ->
			Nick++"#"++Room;
		    #jid{} ->
			%% ???
			jlib:jid_to_string(From)
		end,
	    %% I think this should cover all possible combinations of
	    %% XMPP and non-XMPP error messages...
	    ErrorText =
		error_to_string(xml:get_subtag(El, "error")),
	    send_text_command("", "NOTICE", [State#state.nick,
					     "Message to "++ErrorFrom++" bounced: "++
					     ErrorText], State),
	    {next_state, wait_for_cmd, State};
	_ ->
	    ChannelJID = jlib:jid_remove_resource(From),
	    case ?DICT:find(ChannelJID, State#state.joined) of
		{ok, #channel{}} ->
		    FromNick = From#jid.lresource++jid_to_channel(From, State),
		    Body = xml:get_path_s(El, [{elem, "body"}, cdata]),
		    BodyLines = string:tokens(Body, "\n"),
		    lists:foreach(
		      fun(Line) ->
			      Line1 =
				  case Line of
				      [$/, $m, $e, $  | Action] ->
					  [1]++"ACTION "++Action++[1];
				      _ ->
					  Line
				  end,
			      send_text_command(FromNick, "PRIVMSG", [State#state.nick, Line1], State)
		      end, BodyLines),
		    {next_state, wait_for_cmd, State};
	       _ ->
		    ?INFO_MSG("unexpected message from ~s", [jlib:jid_to_string(From)]),
		    {next_state, wait_for_cmd, State}
	    end
    end;

wait_for_cmd({route, From, To, {xmlelement, "iq", Attrs, _} = El},
	     #state{outgoing_requests = OutgoingRequests} = State) ->
    Type = xml:get_attr_s("type", Attrs),
    Id = xml:get_attr_s("id", Attrs),
    case ?DICT:find(Id, OutgoingRequests) of
	{ok, [F]} when Type == "result"; Type == "error" ->
	    NewState = State#state{outgoing_requests = ?DICT:erase(Id, OutgoingRequests)},
	    F(El, NewState);
	_ when Type == "get"; Type == "set" ->
	    ejabberd_router:route(To, From,
				  jlib:make_error_reply(El, ?ERR_FEATURE_NOT_IMPLEMENTED)),
	    {next_state, wait_for_cmd, State}
    end;

wait_for_cmd(Event, State) ->
    ?INFO_MSG("unexpected event ~p", [Event]),
    {next_state, wait_for_cmd, State}.

remove_nick_from_list(_, []) -> [];
remove_nick_from_list(FromNick, BufferedNicks) -> remove_nick_from_list(FromNick, BufferedNicks, []).

remove_nick_from_list(_, [], NewList) -> NewList;
remove_nick_from_list(FromNick, [{Nick, Role}|BufferedNicks], NewList) ->
	case Nick of
		FromNick -> [NewList|BufferedNicks];
		_ -> remove_nick_from_list(FromNick, BufferedNicks, [NewList|{Nick, Role}])
	end.
	
update_nick_in_list(_, _, []) -> [];
update_nick_in_list(OldNick, NewNick, BufferedNicks) -> update_nick_in_list(OldNick, NewNick, BufferedNicks, []).

update_nick_in_list(_, _, [], NewList) -> NewList;
update_nick_in_list(OldNick, NewNick, [{Nick, Role}|BufferedNicks], NewList) ->
	case Nick of
		OldNick ->
			AllNicks=[NewList|BufferedNicks],
			[{NewNick, Role}|AllNicks];
		_ -> update_nick_in_list(OldNick, NewNick, BufferedNicks, [NewList|{Nick, Role}])
	end.


reply_names([], State) ->
	State;
reply_names([Channel|Channels], State) ->
	case ?DICT:find(channel_to_jid(Channel, State), State#state.joined) of
		{ok, ChannelData} -> reply_names(Channel, ChannelData, State) 
	end,
	reply_names(Channels, State). 

reply_names(Channel, ChannelData, State) ->
    	MyNick = State#state.nick,
	send_reply('RPL_NAMREPLY',
		   [MyNick, "=",
		    Channel,
		    lists:append(
		      lists:map(
			fun({Nick, Role}) ->
				case Role of
				    "moderator" ->
					"@";
				    "participant" ->
					"+";
				    _ ->
					""
				end ++ Nick ++ " "
			end, ChannelData#channel.participants))],
		   State),
	send_reply('RPL_ENDOFNAMES',
		   [Channel,
		    "End of /NAMES list"],
		   State).


join_channels([], _, State) ->
    State;
join_channels(Channels, [], State) ->
    join_channels(Channels, [none], State);
join_channels([Channel | Channels], [Key | Keys],
	      #state{nick = Nick} = State) ->
    Packet =
	{xmlelement, "presence", [],
	 [{xmlelement, "x", [{"xmlns", ?NS_MUC}],
	   case Key of
	       none ->
		   [];
	       _ ->
		   [{xmlelement, "password", [], filter_cdata(Key)}]
	   end}]},
    From = user_jid(State),
    To = channel_nick_to_jid(Nick, Channel, State),
    Room = jlib:jid_remove_resource(To),
    ejabberd_router:route(From, To, Packet),
    NewState = State#state{joining = ?DICT:store(Room, #channel{participants=[]}, State#state.joining)},
    join_channels(Channels, Keys, NewState).

part_channels([], State, _Message) ->
    State;
part_channels([Channel | Channels], State, Message) ->
    Packet =
	{xmlelement, "presence",
	 [{"type", "unavailable"}],
	 case Message of
	    nothing -> [];
	    _ -> [{xmlelement, "status", [],
		  [{xmlcdata, Message}]}]
	 end},
    From = user_jid(State),
    To = channel_nick_to_jid(State#state.nick, Channel, State),
    ejabberd_router:route(From, To, Packet),
    RoomJID = channel_to_jid(Channel, State),
    NewState = State#state{joined = ?DICT:erase(RoomJID, State#state.joined)},
    part_channels(Channels, NewState, Message).

parse_line(Line) ->
    {Line1, LastParam} =
	case string:str(Line, " :") of
	    0 ->
		{Line, []};
	    Index ->
		{string:substr(Line, 1, Index - 1),
		 [string:substr(Line, Index + 2) -- "\r\n"]}
	end,
    Tokens = string:tokens(Line1, " \r\n"),
    {Prefix, Tokens1} =
	case Line1 of
	    [$: | _] ->
		{hd(Tokens), tl(Tokens)};
	    _ ->
		{none, Tokens}
	end,
    [Command | Params] = Tokens1,
    UCCommand = upcase(Command),
    #line{prefix = Prefix, command = UCCommand, params = Params ++ LastParam}.

upcase([]) ->
    [];
upcase([C|String]) ->
    [if $a =< C, C =< $z ->
	     C - ($a - $A);
	true ->
	     C
     end | upcase(String)].

%% sender

send_line(Line, #state{sockmod = SockMod, socket = Socket, encoding = Encoding}) ->
    ?DEBUG("sending ~s", [Line]),
    gen_tcp = SockMod,
    EncodedLine = iconv:convert("utf-8", Encoding, Line),
    ok = gen_tcp:send(Socket, [EncodedLine, 13, 10]).

send_command(Sender, Command, Params, State) ->
    send_command(Sender, Command, Params, State, false).

%% Some IRC software require commands with text to have the text
%% quoted, even it's not if not necessary.
send_text_command(Sender, Command, Params, State) ->
    send_command(Sender, Command, Params, State, true).

send_command(Sender, Command, Params, State, AlwaysQuote) ->
    Prefix = case Sender of
		 "" ->
		     [$: | State#state.host];
		 _ ->
		     [$: | Sender]
	     end,
    ParamString = make_param_string(Params, AlwaysQuote),
    send_line(Prefix ++ " " ++ Command ++ ParamString, State).

send_reply(Reply, Params, State) ->
    Number = case Reply of
		 'ERR_UNKNOWNCOMMAND' ->
		     "421";
		 'ERR_ERRONEUSNICKNAME' ->
		     "432";
		 'ERR_NICKCOLLISION' ->
		     "436";
		 'ERR_NOTONCHANNEL' ->
		     "442";
		 'ERR_NOCHANMODES' ->
		     "477";
		 'ERR_UMODEUNKNOWNFLAG' ->
		     "501";
		 'ERR_USERSDONTMATCH' ->
		     "502";
		 'ERR_NOSUCHCHANNEL' ->
		     "403";
		 'ERR_INVITEONLYCHAN' ->
		     "473";
		 'ERR_NOSUCHSERVER' ->
		     "402";
		 'RPL_UMODEIS' ->
		     "221";
		 'RPL_LISTSTART' ->
		     "321";
		 'RPL_LIST' ->
		     "322";
		 'RPL_LISTEND' ->
		     "323";
		 'RPL_CHANNELMODEIS' ->
		     "324";
		 'RPL_NAMREPLY' ->
		     "353";
		 'RPL_ENDOFNAMES' ->
		     "366";
		 'RPL_BANLIST' ->
		     "367";
		 'RPL_ENDOFBANLIST' ->
		     "368";
		 'RPL_NOTOPIC' ->
		     "331";
		 'RPL_TOPIC' ->
		     "332";
		 'RPL_MOTD' ->
		     "372";
		 'RPL_MOTDSTART' ->
		     "375";
		 'RPL_ENDOFMOTD' ->
		     "376"
	     end,
    send_text_command("", Number, Params, State).

make_param_string([], _) -> "";
make_param_string([LastParam], AlwaysQuote) ->
    case {AlwaysQuote, LastParam, lists:member($\ , LastParam)} of
	{true, _, _} ->
	    " :" ++ LastParam;
	{_, _, true} ->
	    " :" ++ LastParam;
	{_, [$:|_], _} ->
	    " :" ++ LastParam;
	{_, _, _} ->
	    " " ++ LastParam
    end;
make_param_string([Param | Params], AlwaysQuote) ->
    case lists:member($\ , Param) of
	false ->
	    " " ++ Param ++ make_param_string(Params, AlwaysQuote)
    end.

find_el(Name, NS, [{xmlelement, N, Attrs, _} = El|Els]) ->
    XMLNS = xml:get_attr_s("xmlns", Attrs),
    case {Name, NS} of
	{N, XMLNS} ->
	    El;
	_ ->
	    find_el(Name, NS, Els)
    end;
find_el(_, _, []) ->
    nothing.

%as the name says this delivers the jid of a channel name. 
% to #foo it returns foo@example.net
channel_to_jid([$#|Channel], State) ->
    channel_to_jid(Channel, State);
channel_to_jid(Channel, #state{muc_host = MucHost,
			       channels_to_jids = ChannelsToJids}) ->
    case ?DICT:find(Channel, ChannelsToJids) of
	{ok, RoomJID} -> RoomJID;
	_ -> jlib:make_jid(Channel, MucHost, "")
    end.

%this delivers the jid of a channel name including the Nickname as resource 
% to #foo and nick bar it returns foo@example.net/bar
channel_nick_to_jid(Nick, [$#|Channel], State) ->
    channel_nick_to_jid(Nick, Channel, State);
channel_nick_to_jid(Nick, Channel, #state{muc_host = MucHost,
					 channels_to_jids = ChannelsToJids}) ->
    case ?DICT:find(Channel, ChannelsToJids) of
	{ok, RoomJID} -> jlib:jid_replace_resource(RoomJID, Nick);
	_ -> jlib:make_jid(Channel, MucHost, Nick)
    end.

jid_to_channel(#jid{user = Room} = RoomJID,
	       #state{jids_to_channels = JidsToChannels}) ->
    case ?DICT:find(jlib:jid_remove_resource(RoomJID), JidsToChannels) of
	{ok, Channel} -> [$#|Channel];
	_ -> [$#|Room]
    end.

make_irc_sender(Nick, #jid{luser = Room} = RoomJID,
		#state{jids_to_channels = JidsToChannels}) ->
    case ?DICT:find(jlib:jid_remove_resource(RoomJID), JidsToChannels) of
	{ok, Channel} -> Nick++"!"++Nick++"@"++Channel;
	_ -> Nick++"!"++Nick++"@"++Room
    end.
make_irc_sender(#jid{lresource = Nick} = JID, State) ->
    make_irc_sender(Nick, JID, State).

user_jid(#state{user = User, host = Host, realname = Realname}) ->
    jlib:make_jid(User, Host, Realname).

filter_cdata(Msg) ->
    [{xmlcdata, filter_message(Msg)}].

filter_message(Msg) ->
    lists:filter(
      fun(C) ->
	      if (C < 32) and
		 (C /= 3) and
		 (C /= 9) and
		 (C /= 10) and
		 (C /= 13) ->
		      false;
		 true -> true
	      end
      end, Msg).

translate_action(Msg) ->
    case Msg of
	[1, $A, $C, $T, $I, $O, $N, $  | Action] ->
	    "/me "++Action;
	_ ->
	    Msg
    end.

parse_error({xmlelement, "error", _ErrorAttrs, ErrorEls} = ErrorEl) ->
    ErrorTextEl = xml:get_subtag(ErrorEl, "text"),
    ErrorName =
	case ErrorEls -- [ErrorTextEl] of
	    [{xmlelement, ErrorReason, _, _}] ->
		ErrorReason;
	    _ ->
		"unknown error"
	end,
    ErrorText =
	case ErrorTextEl of
	    {xmlelement, _, _, _} ->
		xml:get_tag_cdata(ErrorTextEl);
	    _ ->
		nothing
    end,
    {ErrorName, ErrorText}.

error_to_string({xmlelement, "error", _ErrorAttrs, _ErrorEls} = ErrorEl) ->
    case parse_error(ErrorEl) of
	{ErrorName, ErrorText} when is_list(ErrorText) ->
	    ErrorName ++ ": " ++ ErrorText;
	{ErrorName, _} ->
	    ErrorName
    end;
error_to_string(_) ->
    "unknown error".

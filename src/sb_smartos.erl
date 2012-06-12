%%
%% SmartOS backend for Stableboy.
%% Configuration needed:
%%
%%    {vm, sb_smartos}. %% Or use `-i sb_smartos`
%%    {vm_host, "smartos.local"}. %% Host/IP of global zone
%%    {vm_port, 22}.  %% Defaults to 22, SSH port of global zone
%%    {vm_user, "root"}. %% defaults to "root"
%%    {vm_pass, "pass"}. %% Root password of global zone
%%
%% Usable VMs should be created with some tags that essentially are
%% the config info for the list/0 and get/1 commands.
%%
%% Example:
%%
%% {"tags":{
%%    "platform":"ubuntu",
%%    "version":"12.4.0",
%%    "architecture":"64",
%%    "user":"user",
%%    "password":"password"
%%  }}
%%
%% Tags should be set on VM creation, or set via the `vmadm update`
%% command.

-module(sb_smartos).
-behaviour(stableboy_vm_backend).

-export([list/0, get/1, snapshot/1, rollback/1]).
-define(LISTCMD, "for vm in `vmadm lookup`; do vmadm get $vm | json -o json-0 alias tags; done").

list() ->
    lager:debug("In sb_smartos:list/0"),
    case gzcommand(?LISTCMD, fun format_list/1) of
        {error, _Reason} -> %% TODO: print something?
            ok;
        VMs ->
            sb_vm_common:print_result(VMs)
    end,
    ok.

get(Args) ->
    lager:debug("In sb_smartos:get/1"),
    case filelib:is_file(hd(Args)) of
        true ->
            ok = get_by_file(Args);
        false ->
            ok = get_by_name(Args)
    end.

snapshot(_Args) ->
    lager:debug("In sb_smartos:snapshot/1"),
    ok.

rollback(_Args) ->
    lager:debug("In sb_smartos:rollback/1"),
    ok.

%%-------------------
%% Internal functions
%%-------------------

%% Executes a command in the global zone via SSH.
gzcommand(Command, Callback) ->
    Host = sb:get_config(vm_host),
    Port = sb:get_config(vm_port, 22),
    User = sb:get_config(vm_user, "root"),
    Pass = sb:get_config(vm_pass),
    start_ssh(),
    lager:debug("Connecting to SmartOS GZ: ~s:~p ~s:~s", [Host, Port, User, Pass]),
    case ssh:connect(Host, Port,[{user,User},{password,Pass},{silently_accept_hosts,true}]) of
        {ok, Connection} ->
            case ssh_cmd:run(Connection, Command) of
                {ok, {_,StdOut,_}} ->
                    ssh:close(Connection),
                    Callback(StdOut);
                {error,{Code,_,StdErr}} ->
                    ssh:close(Connection),
                    lager:error("SSH Command failed with code ~p: ~p~n", [Code, StdErr]),
                    {error, {Code, StdErr}}
            end;
        {error, Reason} ->
            lager:error("SSH Command failed with reason: ~p~n", [Reason]),
            {error, Reason}
    end.

start_ssh() ->
    application:start(crypto),
    application:start(ssh).

get_by_file(Args) ->
    lager:debug("In sb_smartos:get_by_file with args: ~p", Args),
    % Read in environment config file
    case file:consult(Args) of
        {ok, Properties} ->
            VMList = gzcommand(?LISTCMD, fun format_list/1),

            Command = "for vm in `vmadm lookup`; do vmadm get $vm | json -o json-0 alias nics tags; done",
            VMInfo = gzcommand(Command, fun format_get/1),
            Count = sb:get_config(count),

            %% attempt to match the properties in the file with available VM's
            case sb_vm_common:match_by_props(VMList, Properties, Count) of
                {ok, SearchResult} ->
                    % The search results come back as the <vms> structure and
                    % and needs to be of the form of vm_info
                    % so translate each using match_by_name
                    lager:debug("get_by_file: SearchResult: ~p", [SearchResult]),
                    PrintResult = fun(SearchRes) ->
                                          % Get the name out
                                          {ok, MBNRes} = sb_vm_common:match_by_name(VMInfo, element(1, SearchRes)),
                                          sb_vm_common:print_result(MBNRes)
                                  end,

                    % Print each result we got back
                    lists:foreach(PrintResult, SearchResult),
                    ok;
                {error, Reason} ->
                    lager:error("Unable to get VM: ~p", [Reason])
            end;

        {error, Reason} ->
            lager:error("Failed to parse file: ~p with error: ~p", [Args, Reason]),
            {error, Reason}
    end.

get_by_name([Alias|_Args]) ->
    Command = "vmadm get `vmadm lookup alias=" ++ Alias ++ "` | json -o json-0 alias nics tags",
    case gzcommand(Command, fun format_get/1) of
        {error, _Reason} -> %% TODO: print something?
            ok;
        VMs ->
            sb_vm_common:print_result(VMs)
    end,
    ok.

format_list(Output) ->
    JSONToVM = fun({struct, JSON}) ->
                       Alias = binary_to_list(proplists:get_value(<<"alias">>, JSON)),
                       {struct, Tags} = proplists:get_value(<<"tags">>, JSON),
                       Platform = list_to_atom(binary_to_list(proplists:get_value(<<"platform">>, Tags))),
                       Version = version_to_intlist(proplists:get_value(<<"version">>, Tags)),
                       Arch = list_to_integer(binary_to_list(proplists:get_value(<<"architecture">>, Tags))),
                       {Alias,Platform,Version,Arch}
               end,
    [ JSONToVM(json2:decode(V)) || V <- re:split(Output, "\n", [{return, binary}, trim]) ].

format_get(Output) ->
    JSONToDetails = fun({struct, JSON}) ->
                            Alias = binary_to_list(proplists:get_value(<<"alias">>, JSON)),
                            {struct, Tags} = proplists:get_value(<<"tags">>, JSON),
                            NICS = proplists:get_value(<<"nics">>, JSON),
                            {struct, NIC} = hd(NICS),
                            IP = binary_to_list(proplists:get_value(<<"ip">>, NIC)),
                            User = binary_to_list(proplists:get_value(<<"user">>, Tags)),
                            Password = binary_to_list(proplists:get_value(<<"password">>, Tags)),
                            %% TODO: FIXME
                            Port = 22,
                            {Alias,IP,Port,User,Password}
                    end,
    [ JSONToDetails(json2:decode(V)) || V <- re:split(Output, "\n", [{return, binary}, trim]) ].

version_to_intlist(V) ->
    [ list_to_integer(P) || P <- re:split(V, "[.]", [{return,list},trim]) ].

-module(mongoapi, [DB]).
% -export([save/1,findOne/2,findOne/1,find/1,find/2,find/3,find/4, update/2, insert/1]).
-compile(export_all).
-include_lib("erlmongo.hrl").

% Dynamically add record information for erlmongo. 
% Records do not have to have recindex as first element (it will be ignored). 
% docid still needs to be either first element (if no recindex) or second (if recindex present).
% For embedded records, use {name_of_record, index_of_record_in_RECTABLE} if embedded record information
%   is in RECTABLE (defined in erlmongo.hrl). If it is not (was added with recinfo), 
%   use {name_of_record, undefined} 
% Example: recinfo(#mydoc{}, record_info(fields, mydoc))
% 		   recinfo(mydoc, record_info(fields, mydoc))
recinfo(RecName, Info) when is_atom(RecName) ->
	put({recinfo, RecName}, Info);
recinfo(Rec, Info) when is_tuple(Rec) ->
	put({recinfo, element(1,Rec)}, Info).

name([_|_] = Collection) ->
	name(list_to_binary(Collection));
name(<<_/binary>> = Collection) ->
	<<DB/binary, ".", Collection/binary>>;
name(Collection) when is_atom(Collection) ->
	name(atom_to_binary(Collection, latin1)).

% Example: remove(#mydoc{},[{#mydoc.docid,Id}])
remove(Rec, Selector) when is_tuple(Rec) ->
	mongodb:exec_delete(name(element(1,Rec)), #delete{selector = mongodb:encoderec_selector(Rec, Selector)});
remove(Col, Selector) ->
	mongodb:exec_delete(name(Col), #delete{selector = mongodb:encode(Selector)}).
	
	
save(Collection, [_|_] = L) ->
	% io:format("Save on ~p~n", [L]),
	case lists:keysearch(<<"_id">>, 1, L) of
		false ->
			OID = mongodb:create_id(),
			case mongodb:exec_insert(name(Collection), #insert{documents = mongodb:encode([{<<"_id">>, {oid, OID}}|L])}) of
				ok ->
					{oid, OID};
				R ->
					R
			end;
		{value, {_, OID}} ->
			case mongodb:exec_update(name(Collection), #update{selector = mongodb:encode([{<<"_id">>, OID}]), document = mongodb:encode(L)}) of
				ok ->
					OID;
				R ->
					R
			end
	end;
save(Collection, Rec) ->
	Offset = mongodb:recoffset(Rec),
	case element(Offset, Rec) of
		undefined ->
			OID = mongodb:create_id(),
			case mongodb:exec_insert(name(Collection), #insert{documents = mongodb:encoderec(setelement(Offset, Rec, {oid, OID}))}) of
				ok ->
					{oid, OID};
				R ->
					R
			end;
		OID ->
			case mongodb:exec_update(name(Collection), 
								#update{selector = mongodb:encode([{<<"_id">>, OID}]), document = mongodb:encoderec(Rec)}) of
				ok ->
					OID;
				R ->
					R
			end
	end.
save(Rec) ->
	save(element(1,Rec), Rec).

% Examples: 
%  update([{#mydoc.name, "docname"}], #mydoc{name = "different name"}, [upsert])
%  update([{#mydoc.name, "docname"}], #mydoc{i = {inc, 1}}, [upsert])
%  update([{#mydoc.name, "docname"}], #mydoc{tags = {push, "lamer"}}, [])
%  update([{#mydoc.name, "docname"}], #mydoc{tags = {pushAll, ["dumbass","jackass"]}}, [upsert])
%  update([{#mydoc.name, "docname"}], #mydoc{tags = {pullAll, ["dumbass","jackass"]}}, [upsert])
%  and so on. 
% modifier list: inc, set, push, pushAll, pop, pull, pullAll
% Flags can be: [upsert,multi]
update(Selector, Rec, Flags) ->
	mongodb:exec_update(name(element(1,Rec)), #update{selector = mongodb:encoderec_selector(Rec, Selector), 
													  upsert = updateflags(Flags,0),
	 												  document = mongodb:encoderec(Rec)}).
update(Collection, [_|_] = Selector, [_|_] = Doc, Flags) ->
	mongodb:exec_update(name(Collection), #update{selector = mongodb:encode(Selector), document = mongodb:encode(Doc), 
								upsert = updateflags(Flags,0)}).
% batchUpdate is not like batchInsert in that everything is one mongo command. With batchUpdate every document becomes
%   a new mongodb command, but they are all encoded and sent at once. So the communication and encoding overhead is smaller.
% Limitations: 
%  - All documents need to be in the same collection
batchUpdate(Sels,Recs,Flags) ->
	[R|_] = Recs,
	mongodb:exec_update(name(element(1,R)), encbu([], Sels,Recs,updateflags(Flags,0))).
	
% Selector and doc are lists of document lists
batchUpdate(Col, [_|_] = Selector, [_|_] = Doc, Flags) ->
	mongodb:exec_update(name(Col),encbu([],Selector,Doc,updateflags(Flags,0))).
	
encbu(L, [Sel|ST],[[_|_] = Doc|DT],Flags) ->
	encbu([#update{selector = mongodb:encode(Sel), document = mongodb:encode(Doc), upsert = Flags}|L],ST,DT,Flags);
encbu(L, [Sel|ST],[Doc|DT],Flags) ->
	encbu([#update{selector = mongodb:encoderec_selector(Doc, Sel), document = mongodb:encoderec(Doc), upsert = Flags}|L],ST,DT,Flags);
encbu(L,[],[],_) ->
	L.	
	
updateflags([upsert|T],V) ->
	updateflags(T,V bor 1);
updateflags([multi|T],V) ->
	updateflags(T,V bor 2);
updateflags([], V) ->
	V.

insert(Col, [_|_] = L) ->
	mongodb:exec_insert(name(Col), #insert{documents = mongodb:encode(L)}).
insert(Rec) ->
	mongodb:exec_insert(name(element(1,Rec)), #insert{documents = mongodb:encoderec(Rec)}).
	
batchInsert(Col, [[_|_]|_] = LRecs) ->
	DocBin = lists:foldl(fun(L, Bin) -> <<Bin/binary, (mongodb:encode(L))/binary>> end, <<>>, LRecs),
	mongodb:exec_insert(name(Col), #insert{documents = DocBin}).
batchInsert(LRecs) ->
	[FRec|_] = LRecs,
	DocBin = lists:foldl(fun(Rec, Bin) -> <<Bin/binary, (mongodb:encoderec(Rec))/binary>> end, <<>>, LRecs),
	mongodb:exec_insert(name(element(1,FRec)), #insert{documents = DocBin}).
	
	
% Advanced queries:
%  Documents with even i:            Mong:find(#mydoc{i = {mod, 2, 0}}, undefined, 0,0).
%  Documents with i larger than 2:   Mong:find(#mydoc{i = {gt, 2}}, undefined, 0,0).
%  Documents with i between 2 and 5: Mong:find(#mydoc{i = {in, {gt, 2}, {lt, 5}}}, undefined, 0,0).
%  in example:     Mong:find(#mydoc{tags = {in, [2,3,4]}}, undefined, 0,0).
%  exists example: Mong:find(#mydoc{tags = {exists, false}}, undefined, 0,0).
%  Advanced query options: gt,lt,gte,lte, ne, in, nin, all, size, exists

findOne(Col, []) ->
	case find(Col, [], undefined, 0, 1) of
		{ok, [Res]} -> {ok, Res};
		{ok, []} -> {ok, []};
		R ->
			R
	end;
findOne(Col, [_|_] = Query) when is_tuple(Col) == false ->
	case find(Col, Query, undefined, 0, 1) of
		{ok, [Res]} -> {ok, Res};
		{ok, []} -> {ok, []};
		R ->
			R
	end;
findOne(Query, Selector) when is_tuple(Query) ->
	case find(Query, Selector, 0, 1) of
		{ok, [Res]} -> {ok, Res};
		{ok, []} -> {ok, []};
		R ->
			R
	end.
	
findOne(Query) when is_tuple(Query) ->
	case find(Query, undefined, 0, 1) of
		{ok, [Res]} -> {ok, Res};
		{ok, []} -> {ok, []};
		R ->
			R
	end.
findOne(Col, [_|_] = Query, [_|_] = Selector) ->
	case find(Col, Query, Selector, 0, 1) of
		{ok, [Res]} -> {ok, Res};
		{ok, []} -> {ok, []};
		R ->
			R
	end.

find(Col, #search{} = Q) ->
	find(Col, Q#search.criteria, Q#search.field_selector, Q#search.nskip, Q#search.ndocs).
find(#search{} = Q) ->
	find(Q#search.criteria, Q#search.field_selector, Q#search.nskip, Q#search.ndocs).
	
find(Col, Query, Selector, From, Limit) when is_list(Query) ->
	Quer = #search{ndocs = Limit, nskip = From, criteria = mongodb:encode(Query), field_selector = mongodb:encode(Selector)},
	case mongodb:exec_find(name(Col), Quer) of
		not_connected ->
			not_connected;
		<<>> ->
			{ok, []};
		Res ->
			{ok, mongodb:decode(Res)}
	end;
find(Col, Query, Selector, From, Limit) ->
	Quer = #search{ndocs = Limit, nskip = From, criteria = mongodb:encode_findrec(Query), field_selector = mongodb:encoderec_selector(Query, Selector)},
	case mongodb:exec_find(name(Col), Quer) of
		not_connected ->
			not_connected;
		<<>> ->
			{ok, []};
		Result ->
			{ok, mongodb:decoderec(Query, Result)}
			% try mongodb:decoderec(Query, Result) of
			% 	Res ->
			% 		Res
			% catch
			% 	error:_ ->
			% 		mongodb:decode(Result)
			% end
	end.
find(Query, Selector, From, Limit) ->
	find(element(1,Query), Query, Selector, From, Limit).

% opts: [reverse, {sort, SortyBy}, explain, {hint, Hint}, snapshot]
% SortBy: {key, Val} or a list of keyval tuples -> {i,1}  (1 = ascending, -1 = descending)
% Hint: key
findOpt(Col, Query, Selector, Opts, From, Limit) when is_list(Query) ->
	find(Col, translateopts(undefined, Opts,[{<<"query">>, Query}]), Selector, From, Limit);
% SortBy examples: {#mydoc.name, 1}, [{#mydoc.i, 1},{#mydoc.name,-1}]
% Hint example: #mydoc.name
findOpt(Col, Query, Selector, Opts, From, Limit) ->
	Quer = #search{ndocs = Limit, nskip = From, field_selector = mongodb:encoderec_selector(Query, Selector),
	             criteria = mongodb:encode(translateopts(Query, Opts,[{<<"query">>, {bson, mongodb:encode_findrec(Query)}}]))}, 
	case mongodb:exec_find(name(Col), Quer) of
		not_connected ->
			not_connected;
		<<>> ->
			{ok, []};
		Result ->
			% If opt is explain, it will crash
			try mongodb:decoderec(Query, Result) of
				Res ->
					{ok, Res}
			catch
				error:_ ->
					{ok, mongodb:decode(Result)}
			end
	end.
findOpt(Query, Selector, Opts, From, Limit) ->
	findOpt(element(1,Query), Query, Selector, Opts, From, Limit).
findOpt(Col, #search{} = Q, Opts) ->
	findOpt(Col, Q#search.criteria, Q#search.field_selector, Opts, Q#search.nskip, Q#search.ndocs).
findOpt(#search{} = Q, Opts) ->
	findOpt(Q#search.criteria, Q#search.field_selector, Opts, Q#search.nskip, Q#search.ndocs).
	
cursor(Query, Selector, Opts, From, Limit) ->
	Quer = #search{ndocs = Limit, nskip = From, field_selector = mongodb:encoderec_selector(Query, Selector),
	             criteria = mongodb:encode(translateopts(Query, Opts,[{<<"query">>, {bson, mongodb:encode_findrec(Query)}}])),
				 opts = ?QUER_OPT_CURSOR},
	case mongodb:exec_cursor(name(element(1,Query)), Quer) of
		not_connected ->
			not_connected;
		{done, <<>>} ->
			{done, []};
		{done, Result} ->
			{done, mongodb:decoderec(Query, Result)};
		{Cursor, Result} ->
			{ok, Cursor, mongodb:decoderec(Query, Result)}
	end.
getMore(Rec, Cursor) ->
	case mongodb:exec_getmore(name(element(1,Rec)), Cursor) of
		not_connected ->
			not_connected;
		{done, <<>>} ->
			{done, []};
		{done, Result} ->
			{done, mongodb:decoderec(Rec, Result)};
		{ok, Result} ->
			{ok, mongodb:decoderec(Rec, Result)}
	end.
closeCursor(Cur) ->
	Cur#cursor.pid ! {cleanup},
	ok.
	
translateopts(undefined, [{sort, [_|_] = SortBy}|T], L) ->
	translateopts(undefined, T, [{<<"orderby">>, SortBy}|L]);
translateopts(undefined, [{sort, {Key,Val}}|T], L) ->
	translateopts(undefined, T, [{<<"orderby">>, [{Key,Val}]}|L]);
translateopts(Rec, [{sort, [_|_] = SortBy}|T], L) ->
	translateopts(Rec, T, [{<<"orderby">>, {bson, mongodb:encoderec_selector(Rec, SortBy)}}|L]);
translateopts(Rec, [{sort, {Key,Val}}|T], L) ->
	translateopts(Rec, T, [{<<"orderby">>, {bson, mongodb:encoderec_selector(Rec, [{Key,Val}])}}|L]);
translateopts(Rec, [reverse|T], L) ->
	translateopts(Rec, T, [{<<"orderby">>, [{<<"$natural">>, -1}]}|L]);	
translateopts(Rec, [explain|T], L) ->
	translateopts(Rec, T, [{<<"$explain">>, true}|L]);
translateopts(Rec, [snapshot|T], L) ->
	translateopts(Rec, T, [{<<"$snapshot">>, true}|L]);	
translateopts(undefined, [hint, Hint|T], L) ->
	translateopts(undefined, T, [{<<"$hint">>, [{Hint, 1}]}|L]);
translateopts(Rec, [hint, Hint|T], L) ->
	translateopts(Rec, T, [{<<"$hint">>, {bson, mongodb:encoderec_selector([Hint])}}|L]);
translateopts(_, [], L) ->
	L.

% If you wish to index on an embedded document, use proplists.
% Example: ensureIndex(<<"mydoc">>, [{<<"name">>, 1}]).
%  You can use lists, they will be turned into binaries.
ensureIndex([_|_] = Collection, Keys) ->
	ensureIndex(list_to_binary(Collection), Keys);
ensureIndex(<<_/binary>> = Collection, Keys) ->
	Bin = mongodb:encode([{plaintext, <<"name">>, mongodb:gen_prop_keyname(Keys, <<>>)},
	 					  {plaintext, <<"ns">>, name(Collection)},
	                      {<<"key">>, {bson, mongodb:encode(Keys)}}]),
	mongodb:ensureIndex(DB, Bin);
% Example: ensureIndex(#mydoc{}, [{#mydoc.name, 1}])
ensureIndex(Rec, Keys) ->
	Bin = mongodb:encode([{plaintext, <<"name">>, mongodb:gen_keyname(Rec, Keys)}, 
			              {plaintext, <<"ns">>, name(element(1,Rec))}, 
			              {<<"key">>, {bson, mongodb:encoderec_selector(Rec, Keys)}}]),
	mongodb:ensureIndex(DB, Bin).
	
deleteIndexes([_|_] = Collection) ->
	deleteIndexes(list_to_binary(Collection));
deleteIndexes(<<_/binary>> = Collection) ->
	mongodb:clearIndexCache(),
	mongodb:exec_cmd(DB, [{plaintext, <<"deleteIndexes">>, Collection}, {plaintext, <<"index">>, <<"*">>}]).

deleteIndex(Rec, Key) ->
	mongodb:clearIndexCache(),
	mongodb:exec_cmd(DB,[{plaintext, <<"deleteIndexes">>, atom_to_binary(element(1,Rec), latin1)},
				  		 {plaintext, <<"index">>, mongodb:gen_keyname(Rec,Key)}]).

% How many documents in mydoc collection: Mong:count("mydoc").
%										  Mong:count(#mydoc{}). 
% How many documents with i larger than 2: Mong:count(#mydoc{i = {gt, 2}}).
count(Col) ->
	count(Col,undefined).
count(ColIn, Query) ->
	case true of
		_ when is_list(ColIn) ->
			Col = list_to_binary(ColIn);
		_ when is_tuple(ColIn) ->
			Col = atom_to_binary(element(1,ColIn), latin1);
		_ ->
			Col = ColIn
	end,
	case true of
		_ when is_list(Query) ->
			Cmd = [{plaintext, <<"count">>, Col}, {plaintext, <<"ns">>, DB}, {<<"query">>, {bson, mongodb:encode(Query)}}];
		_ when is_tuple(ColIn), Query == undefined ->
			Cmd = [{plaintext, <<"count">>, Col}, {plaintext, <<"ns">>, DB}, {<<"query">>, {bson, mongodb:encoderec(ColIn)}}];
		_ when is_tuple(ColIn), is_tuple(Query) ->
			Cmd = [{plaintext, <<"count">>, Col}, {plaintext, <<"ns">>, DB}, {<<"query">>, {bson, mongodb:encoderec(Query)}}];
		_ when Query == undefined ->
			Cmd = [{plaintext, <<"count">>, Col}, {plaintext, <<"ns">>, DB}]
	end,
	case mongodb:exec_cmd(DB, Cmd) of
		[{<<"n">>, Val}|_] ->
			round(Val);
		_ ->
			false
	end.
	

addUser(U, P) when is_binary(U) ->
	addUser(binary_to_list(U),P);
addUser(U, P) when is_binary(P) ->
	addUser(U,binary_to_list(P));
addUser(Username, Password) ->
	save(<<"system.users">>, [{<<"user">>, Username},
							  {<<"pwd">>, mongodb:dec2hex(<<>>, erlang:md5(Username ++ ":mongo:" ++ Password))}]).

	
% Runs $cmd. Parameters can be just a string it will be converted into {string,1}
runCmd({_,_} = T) ->
	runCmd([T]);
runCmd([{_,_}|_] = L) ->
	mongodb:exec_cmd(DB, L);
runCmd([_|_] = L) ->
	runCmd([{L,1}]);
runCmd(<<_/binary>> = L) ->
	runCmd(binary_to_list(L)).

stats(C) when is_tuple(C) ->
	stats(atom_to_binary(element(1,C),latin1));
stats(Collection) ->
	runCmd([{"collstats", Collection}]).

repairDatabase() ->
	runCmd([{"repairDatabase", 1}]).
dropDatabase() ->
	runCmd([{"dropDatabase", 1}]).
cloneDatabase(From) when is_list(From); is_binary(From) ->
	runCmd([{"clone", From}]).

dropCollection(C) when is_tuple(C) ->
	dropCollection(atom_to_binary(element(1,C),latin1));
dropCollection(Collection) ->
	mongodb:clearIndexCache(),
	runCmd([{"drop", Collection}]).

createCollection(Name) ->
	createCollection(Name, []).
% Options: idindex, noidindex, capped, {size, MaxSizeBytes}, {max, MaxElements}
createCollection(Name, L) when is_tuple(Name) ->
	createCollection(atom_to_binary(element(1,Name), latin1), L);
createCollection(Name, L) ->
	runCmd([{<<"create">>, Name}] ++ translatecolopts(L, [])).

translatecolopts([idindex|T], O) ->
	translatecolopts(T, [{<<"autoIndexId">>, true}|O]);	
translatecolopts([noidindex|T], O) ->
	translatecolopts(T, [{<<"autoIndexId">>, false}|O]);	
translatecolopts([capped|T], O) ->
	translatecolopts(T, [{<<"capped">>, true}|O]);	
translatecolopts([{size, MaxSize}|T], O) ->
	translatecolopts(T, [{<<"size">>, MaxSize}|O]);
translatecolopts([{max, Max}|T], O) ->
	translatecolopts(T, [{<<"max">>, Max}|O]);
translatecolopts([], O) ->
	O.
	
setProfilingLevel(L) when is_integer(L) ->
	case true of
		_ when L > 0 ->
			createCollection(<<"system.profile">>, [capped, {size, 131072}]);
		_ when L >= 0, L =< 2 ->
			true
	end,
	runCmd([{"profile", L}]).
getProfilingLevel() ->
	runCmd([{"profile", -1}]).


gfsNew(Filename) ->
	gfsNew(<<"fd">>, Filename, []).
gfsNew(Filename, Opts) ->
	gfsNew(<<"fd">>, Filename, Opts).
gfsNew([_|_] = Collection, Filename, Opts) ->
	gfsNew(list_to_binary(Collection), Filename, Opts);
gfsNew(<<_/binary>> = Collection, Filename, Opts) ->
	mongodb:startgfs(gfsopts(Opts,#gfs_state{file = #gfs_file{filename = Filename, length = 0, chunkSize = 262144,
															  docid = mongodb:create_id(), uploadDate = now()},
	 										 collection = name(Collection), db = DB, mode = write})).
	% Name = name(<<Collection/binary, ".file">>).
	
gfsopts([{meta, Rec}|T], S) ->
	gfsopts(T, S#gfs_state{file = (S#gfs_state.file)#gfs_file{metadata = Rec}});
gfsopts([{aliases, L}|T], S) ->
	gfsopts(T, S#gfs_state{file = (S#gfs_state.file)#gfs_file{aliases = {array, L}}});
gfsopts([{mime, Mime}|T], S) ->
	gfsopts(T, S#gfs_state{file = (S#gfs_state.file)#gfs_file{contentType = Mime}});
gfsopts([{chunkSize, Size}|T], S) ->
	gfsopts(T, S#gfs_state{file = (S#gfs_state.file)#gfs_file{chunkSize = Size}});
gfsopts([{flushLimit, Limit}|T], S) ->
	gfsopts(T, S#gfs_state{flush_limit = Limit});
gfsopts([_|T], S) ->
	gfsopts(T,S);
gfsopts([], S) ->
	S.
	
gfsWrite(PID, Bin) ->
	PID ! {write, Bin},
	ok.
gfsFlush(PID) ->
	PID ! {flush},
	ok.
gfsClose(PID) ->
	unlink(PID),
	PID ! {close},
	ok.

gfsOpen(R) ->
	gfsOpen(<<"fd">>, R).
gfsOpen([_|_] = Col, R) ->
	gfsOpen(list_to_binary(Col),R);
gfsOpen(Collection, R) ->
	case R#gfs_file.docid of
		undefined ->			
			Quer = #search{ndocs = 1, nskip = 0, criteria = mongodb:encode_findrec(R)},
			case mongodb:exec_find(name(<<Collection/binary, ".files">>), Quer) of
				not_connected ->
					not_connected;
				<<>> ->
					[];
				Result ->
					[DR] = mongodb:decoderec(R, Result),
					gfsOpen(DR)
			end;
		_ ->
			% R
			mongodb:startgfs(#gfs_state{file = R, collection = name(Collection), db = DB, mode = read})
	end.

gfsRead(PID, N)	->
	PID ! {read, self(), N},
	receive
		{gfs_bytes, Bin} ->
			Bin
		after 5000 ->
			false
	end.

gfsDelete(R) ->
	gfsDelete(<<"fd">>, R).
gfsDelete([_|_] = Col, R) ->
	gfsDelete(list_to_binary(Col),R);
gfsDelete(Collection, R) ->
	case R#gfs_file.docid of
		undefined ->			
			Quer = #search{ndocs = 1, nskip = 0, criteria = mongodb:encode_findrec(R)},
			case mongodb:exec_find(name(<<Collection/binary, ".files">>), Quer) of
				not_connected ->
					not_connected;
				<<>> ->
					[];
				Result ->
					[DR] = mongodb:decoderec(R, Result),
					gfsDelete(DR)
			end;
		_ ->
			% NChunks = (R#gfs_file.length div R#gfs_file.chunkSize) + 1,
			remove(<<Collection/binary, ".files">>, [{<<"_id">>, {oid, R#gfs_file.docid}}]),
			remove(<<Collection/binary, ".chunks">>, [{<<"files_id">>, {oid, R#gfs_file.docid}}])
	end.
			
			
testw(Mong, Filename) ->
	spawn(fun() ->
			% If the calling process does gfsNew, gfsWrite and dies immediately after, 
			%  gfsClose is necesssary. This is because of a race condition.
			%  Both calls will complete before gfs gets the chance to set trap_exit to true and detect
			%  the caller has died.
			{ok,Bin} = file:read_file(Filename),
			PID = Mong:gfsNew(Filename),
			Mong:gfsWrite(PID,Bin),
			Mong:gfsClose(PID)
		  end).
	
	
	
%% Translate Elixir quoted expressions to Erlang Abstract Format.
%% Expects the tree to be expanded.
-module(elixir_translator).
-export([translate_many/2, translate/2, translate_arg/3, translate_args/2]).
-import(elixir_scope, [mergev/2, mergec/2, mergef/2]).
-import(elixir_errors, [compile_error/3, compile_error/4]).
-include("elixir.hrl").

translate_many(Forms, S) ->
  lists:mapfoldl(fun translate/2, S, Forms).

%% =

translate({ '=', Meta, [Left, Right] }, S) ->
  { TRight, SR } = translate(Right, S),
  { TLeft, SL } = elixir_clauses:match(fun translate/2, Left, SR),
  { { match, ?line(Meta), TLeft, TRight }, SL };

%% Containers

translate({ '%{}', Meta, Args }, S) when is_list(Args) ->
  { TArgs, SE } = translate_map_args(Args, Meta, S),
  { { map, ?line(Meta), TArgs }, SE };

translate({ '{}', Meta, Args }, S) when is_list(Args) ->
  { TArgs, SE } = translate_args(Args, S),
  { { tuple, ?line(Meta), TArgs }, SE };

translate({ '<<>>', Meta, Args }, S) when is_list(Args) ->
  elixir_bitstring:translate(Meta, Args, S);

%% Blocks and scope rewriters

translate({ '__block__', Meta, Args }, S) when is_list(Args) ->
  { TArgs, NS } = translate_many(Args, S),
  { { block, ?line(Meta), TArgs }, NS };

%% Erlang op

translate({ '__op__', Meta, [Op, Expr] }, S) when is_atom(Op) ->
  { TExpr, NS } = translate(Expr, S),
  { { op, ?line(Meta), Op, TExpr }, NS };

translate({ '__op__', Meta, [Op, Left, Right] }, S) when is_atom(Op) ->
  { [TLeft, TRight], NS }  = translate_args([Left, Right], S),
  { { op, ?line(Meta), Op, TLeft, TRight }, NS };

%% Lexical

translate({ Lexical, _, [_, _] }, S) when Lexical == import; Lexical == alias; Lexical == require ->
  { { atom, 0, nil }, S };

%% Pseudo variables

translate({ '__CALLER__', Meta, Atom }, S) when is_atom(Atom) ->
  { { var, ?line(Meta), '__CALLER__' }, S#elixir_scope{caller=true} };

%% Functions

translate({ '&', Meta, [{ '/', [], [{ Fun, [], Atom }, Arity] }] }, S)
    when is_atom(Fun), is_atom(Atom), is_integer(Arity) ->
  { { 'fun', ?line(Meta), { function, Fun, Arity } }, S };
translate({ '&', Meta, [Arg] }, S) when is_integer(Arg) ->
  compile_error(Meta, S#elixir_scope.file, "unhandled &~B outside of a capture", [Arg]);

translate({ fn, Meta, Clauses }, S) ->
  elixir_fn:translate(Meta, Clauses, S);

%% Case

translate({'case', Meta, [Expr, KV]}, S) when is_list(KV) ->
  Clauses = elixir_clauses:get_pairs(do, KV),
  { TExpr, NS } = translate(Expr, S),

  RClauses = case elixir_utils:returns_boolean(TExpr) of
    true  -> rewrite_case_clauses(Clauses);
    false -> Clauses
  end,

  { TClauses, TS } = elixir_clauses:clauses(Meta, RClauses, NS),
  { { 'case', ?line(Meta), TExpr, TClauses }, TS };

%% Try

translate({'try', Meta, [Clauses]}, RS) when is_list(Clauses) ->
  S  = RS#elixir_scope{noname=true},
  Do = proplists:get_value('do', Clauses, nil),
  { TDo, SB } = elixir_translator:translate(Do, S),

  Catch = [Tuple || { X, _ } = Tuple <- Clauses, X == 'rescue' orelse X == 'catch'],
  { TCatch, SC } = elixir_try:clauses(Meta, Catch, mergec(S, SB)),

  After = proplists:get_value('after', Clauses, nil),
  { TAfter, SA } = translate(After, mergec(S, SC)),

  Else = elixir_clauses:get_pairs(else, Clauses),
  { TElse, SE } = elixir_clauses:clauses(Meta, Else, mergec(S, SA)),

  SF = (mergec(S, SE))#elixir_scope{noname=RS#elixir_scope.noname},
  { { 'try', ?line(Meta), unblock(TDo), TElse, TCatch, unblock(TAfter) }, SF };

%% Receive

translate({'receive', Meta, [KV] }, S) when is_list(KV) ->
  Do = elixir_clauses:get_pairs(do, KV, true),

  case lists:keyfind('after', 1, KV) of
    false ->
      { TClauses, SC } = elixir_clauses:clauses(Meta, Do, S),
      { { 'receive', ?line(Meta), TClauses }, SC };
    _ ->
      After = elixir_clauses:get_pairs('after', KV),
      { TClauses, SC } = elixir_clauses:clauses(Meta, Do ++ After, S),
      { FClauses, TAfter } = elixir_utils:split_last(TClauses),
      { _, _, [FExpr], _, FAfter } = TAfter,
      { { 'receive', ?line(Meta), FClauses, FExpr, FAfter }, SC }
  end;

%% Comprehensions

translate({ Kind, Meta, Args }, S) when is_list(Args), (Kind == lc) orelse (Kind == bc) ->
  translate_comprehension(Meta, Kind, Args, S);

%% Super

translate({ super, Meta, Args }, S) when is_list(Args) ->
  Module = assert_module_scope(Meta, super, S),
  Function = assert_function_scope(Meta, super, S),
  elixir_def_overridable:ensure_defined(Meta, Module, Function, S),

  { _, Arity } = Function,

  { TArgs, TS } = if
    length(Args) == Arity ->
      translate_args(Args, S);
    true ->
      compile_error(Meta, S#elixir_scope.file, "super must be called with the same number of "
                    "arguments as the current function")
  end,

  Super = elixir_def_overridable:name(Module, Function),
  { { call, ?line(Meta), { atom, ?line(Meta), Super }, TArgs }, TS#elixir_scope{super=true} };

%% Variables

translate({ '^', Meta, [ { Name, VarMeta, Kind } = Var ] },
               #elixir_scope{extra=fn_match, extra_guards=Extra} = S) when is_atom(Name), is_atom(Kind) ->
  Tuple = { Name, var_kind(VarMeta, Kind) },
  case orddict:find(Tuple, S#elixir_scope.backup_vars) of
    { ok, { Value, _Counter } } ->
      Line = ?line(Meta),
      { TVar, TS } = translate(Var, S),
      Guard = { op, Line, '=:=', { var, ?line(Meta), Value }, TVar },
      { TVar, TS#elixir_scope{extra_guards=[Guard|Extra]} };
    error ->
      compile_error(Meta, S#elixir_scope.file, "unbound variable ^~ts", [Name])
  end;

translate({ '^', Meta, [ { Name, VarMeta, Kind } ] }, #elixir_scope{context=match} = S) when is_atom(Name), is_atom(Kind) ->
  Tuple = { Name, var_kind(VarMeta, Kind) },
  case orddict:find(Tuple, S#elixir_scope.backup_vars) of
    { ok, { Value, _Counter } } ->
      { { var, ?line(Meta), Value }, S };
    error ->
      compile_error(Meta, S#elixir_scope.file, "unbound variable ^~ts", [Name])
  end;

translate({ '_', Meta, Kind }, #elixir_scope{context=match} = S) when is_atom(Kind) ->
  { { var, ?line(Meta), '_' }, S };

translate({ '_', Meta, Kind }, S) when is_atom(Kind) ->
  compile_error(Meta, S#elixir_scope.file, "unbound variable _");

translate({ Name, Meta, Kind }, S) when is_atom(Name), is_atom(Kind) ->
  elixir_scope:translate_var(Meta, Name, var_kind(Meta, Kind), S);

%% Local calls

translate({ Name, Meta, Args }, S) when is_atom(Name), is_list(Meta), is_list(Args) ->
  if
    S#elixir_scope.context == match ->
      compile_error(Meta, S#elixir_scope.file,
                    "cannot invoke function ~ts/~B inside match", [Name, length(Args)]);
    S#elixir_scope.context == guard ->
      Arity = length(Args),
      File  = S#elixir_scope.file,
      case Arity of
        0 -> compile_error(Meta, File, "unknown variable ~ts or cannot invoke "
                           "function ~ts/~B inside guard", [Name, Name, Arity]);
        _ -> compile_error(Meta, File, "cannot invoke local ~ts/~B inside guard",
                           [Name, Arity])
      end;
    S#elixir_scope.function == nil ->
      compile_error(Meta, S#elixir_scope.file, "undefined function ~ts/~B", [Name, length(Args)]);
    true ->
      Line = ?line(Meta),
      { TArgs, NS } = translate_args(Args, S),
      { { call, Line, { atom, Line, Name }, TArgs }, NS }
  end;

%% Remote calls

translate({ { '.', _, [Left, Right] }, Meta, Args }, S)
    when (is_tuple(Left) orelse is_atom(Left)), is_atom(Right), is_list(Meta), is_list(Args) ->
  { TLeft, SL } = translate(Left, S),
  { TArgs, SA } = translate_args(Args, mergec(S, SL)),

  Line  = ?line(Meta),
  Arity = length(Args),

  %% We need to rewrite erlang function calls as operators
  %% because erl_eval chokes on them. We can remove this
  %% once a fix is merged into Erlang, keeping only the
  %% list operators one (since it is required for inlining
  %% [1,2,3] ++ Right in matches).
  case (Left == erlang) andalso erl_op(Right, Arity) of
    true ->
      { list_to_tuple([op, Line, Right] ++ TArgs), mergev(SL, SA) };
    false ->
      assert_allowed_in_context(Meta, Left, Right, Arity, S),
      { { call, Line, { remote, Line, TLeft, { atom, 0, Right } }, TArgs }, mergev(SL, SA) }
  end;

%% Anonymous function calls

translate({ { '.', _, [Expr] }, Meta, Args }, S) when is_list(Args) ->
  { TExpr, SE } = translate(Expr, S),
  { TArgs, SA } = translate_args(Args, mergec(S, SE)),
  { { call, ?line(Meta), TExpr, TArgs }, mergev(SE, SA) };

%% Literals

translate(List, S) when is_list(List) ->
  Fun = case S#elixir_scope.context of
    match -> fun translate/2;
    _     -> fun(X, Acc) -> translate_arg(X, Acc, S) end
  end,
  translate_list(List, Fun, S, []);

translate({ Left, Right }, S) ->
  { TArgs, SE } = translate_args([Left, Right], S),
  { { tuple, 0, TArgs }, SE };

translate(Other, S) ->
  { elixir_utils:elixir_to_erl(Other), S }.

%% Helpers

erl_op(Op, Arity) ->
  erl_internal:list_op(Op, Arity) orelse
    erl_internal:comp_op(Op, Arity) orelse
    erl_internal:bool_op(Op, Arity) orelse
    erl_internal:arith_op(Op, Arity).

translate_list([{ '|', _, [_, _]=Args}], Fun, Acc, List) ->
  { [TLeft,TRight], TAcc } = lists:mapfoldl(Fun, Acc, Args),
  { build_list([TLeft|List], TRight), TAcc };
translate_list([H|T], Fun, Acc, List) ->
  { TH, TAcc } = Fun(H, Acc),
  translate_list(T, Fun, TAcc, [TH|List]);
translate_list([], _Fun, Acc, List) ->
  { build_list(List, { nil, 0 }), Acc }.

build_list([H|T], Acc) ->
  build_list(T, { cons, 0, H, Acc });
build_list([], Acc) ->
  Acc.

var_kind(Meta, Kind) ->
  case lists:keyfind(counter, 1, Meta) of
    { counter, Counter } -> Counter;
    false -> Kind
  end.

%% Case

rewrite_case_clauses([
    {do,Meta1,[{'when',_,[{V,M,C},{'__op__',_,['orelse',_,_]}]}],False},
    {do,Meta2,[{'_',_,UC}],True}] = Clauses)
    when is_atom(V), is_list(M), is_atom(C), is_atom(UC) ->
  case lists:keyfind('cond', 1, M) of
    {'cond',true} ->
      [{do,Meta1,[false],False},{do,Meta2,[true],True}];
    _ ->
      Clauses
  end;
rewrite_case_clauses(Clauses) ->
  Clauses.

%% Pack a list of expressions from a block.
unblock({ 'block', _, Exprs }) -> Exprs;
unblock(Expr)                  -> [Expr].

%% Translate args
translate_arg(Arg, Acc, S) when is_number(Arg); is_atom(Arg); is_binary(Arg); is_pid(Arg); is_function(Arg) ->
  { TArg, _ } = translate(Arg, S),
  { TArg, Acc };
translate_arg(Arg, Acc, S) ->
  { TArg, TAcc } = translate(Arg, mergec(S, Acc)),
  { TArg, mergev(Acc, TAcc) }.

translate_args(Args, #elixir_scope{context=match} = S) ->
  translate_many(Args, S);

translate_args(Args, S) ->
  lists:mapfoldl(fun(X, Acc) -> translate_arg(X, Acc, S) end, S, Args).

%% Translate map args

translate_map_args(Args, Meta, #elixir_scope{context=Match} = S) ->
  lists:mapfoldl(fun({Key, Value}, Acc) ->
                    case Match of
                       match ->
                         {TKey, Acc1} = translate_arg(Key, Acc, S),
                         {TValue, Acc2} = translate_arg(Value, Acc1, S),
                         {{map_field_exact, ?line(Meta), TKey, TValue}, Acc2};
                       _     ->
                         {TKey, Acc1} = translate_arg(Key, Acc, S),
                         {TValue, Acc2} = translate_arg(Value, Acc1, S),
                         {{map_field_assoc, ?line(Meta), TKey, TValue}, Acc2}
                     end
                 end, S, Args).

%% Comprehensions

translate_comprehension(Meta, Kind, Args, S) ->
  { Cases, [{do,Expr}] } = elixir_utils:split_last(Args),
  { TCases, SC } = lists:mapfoldl(fun(C, Acc) -> translate_comprehension_clause(Meta, C, Acc) end, S, Cases),
  { TExpr, SE }  = translate_comprehension_do(Meta, Kind, Expr, SC),
  { { Kind, ?line(Meta), TExpr, TCases }, mergef(S, SE) }.

translate_comprehension_do(_Meta, bc, { '<<>>', _, _ } = Expr, S) ->
  translate(Expr, S);

translate_comprehension_do(Meta, bc, _Expr, S) ->
  compile_error(Meta, S#elixir_scope.file, "a bit comprehension expects a bit string << >> to be returned");

translate_comprehension_do(_Meta, _Kind, Expr, S) ->
  translate(Expr, S).

translate_comprehension_clause(_Meta, {inbits, Meta, [{ '<<>>', _, _} = Left, Right]}, S) ->
  { TRight, SR } = translate(Right, S),
  { TLeft, SL  } = elixir_clauses:match(fun elixir_translator:translate/2, Left, SR),
  { { b_generate, ?line(Meta), TLeft, TRight }, SL };

translate_comprehension_clause(_Meta, {inbits, Meta, [_Left, _Right]}, S) ->
  compile_error(Meta, S#elixir_scope.file, "a bit comprehension expects a bit string << >> to be used in inbits generators");

translate_comprehension_clause(_Meta, {inlist, Meta, [Left, Right]}, S) ->
  { TRight, SR } = translate(Right, S),
  { TLeft, SL  } = elixir_clauses:match(fun elixir_translator:translate/2, Left, SR),
  { { generate, ?line(Meta), TLeft, TRight }, SL };

translate_comprehension_clause(Meta, X, S) ->
  Line = ?line(Meta),
  { TX, TS } = translate(X, S),
  { BX, BS } = elixir_utils:convert_to_boolean(Line, TX, true, TS),
  { { match, Line, { var, Line, '_' }, BX }, BS }.

%% Assertions

assert_module_scope(Meta, Kind, #elixir_scope{module=nil,file=File}) ->
  compile_error(Meta, File, "cannot invoke ~ts outside module", [Kind]);
assert_module_scope(_Meta, _Kind, #elixir_scope{module=Module}) -> Module.

assert_function_scope(Meta, Kind, #elixir_scope{function=nil,file=File}) ->
  compile_error(Meta, File, "cannot invoke ~ts outside function", [Kind]);
assert_function_scope(_Meta, _Kind, #elixir_scope{function=Function}) -> Function.

assert_allowed_in_context(Meta, Left, Right, Arity, #elixir_scope{context=Context} = S)
    when (Context == match) orelse (Context == guard) ->
  case (Left == erlang) andalso erl_internal:guard_bif(Right, Arity) of
    true  -> ok;
    false ->
      compile_error(Meta, S#elixir_scope.file, "cannot invoke remote function ~ts.~ts/~B inside ~ts",
        ['Elixir.Macro':to_string(Left), Right, Arity, Context])
  end;
assert_allowed_in_context(_, _, _, _, _) ->
  ok.

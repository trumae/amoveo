-module(trees2).
-export([test/1, decompress_pub/1, merkle2verkle/2, root_hash/1, get_proof/3, hash_key/2, key/1, serialize/1, store_things/2, verify_proof/2, deserialize/2, store_verified/2, update_proof/2, compress_pub/1]).

-include("../../records.hrl").
%-record(exist, {hash, height}).
-record(unmatched, {account, %pubkey of the account
		    oracle, %oracle id
		    amount,
		    pointer}).
-record(receipt, {id, tid, pubkey, nonce}).

-define(sanity, false).
    

root_hash(Loc) ->
    CFG = tree:cfg(amoveo),
    stem_verkle:hash_point(
      stem_verkle:root(
        stem_verkle:get(Loc, CFG))).

range(N, N) ->
    [N];
range(N, M) when N < M ->
    [N|range(N+1, M)].

%kinds of trees
% {acc, balance, nonce, pubkey}
% {exist, hash, height}
% {oracle, id, result, question, starts, type, orders, creator, done_timer}
% {matched, amount, oracle, true, false, bad}
% {unmatched, account, oracle, amount, pointer}
% {sub_acc, balance, nonce, pubkey, contract_id, type}
% {contract, code, many_types, nonce, last_modified, delay, closed, result, source, source_type, sink, volume}
% {trade, height, value}
% {market, id, cid1, type1, amount1, cid2, type2, amount2, shares}
% {receipt, id, tid, pubkey, nonce}

type2int(acc) -> 1;
type2int(oracle) -> 3;
type2int(matched) -> 4;
type2int(unmatched) -> 5;
type2int(sub_acc) -> 6;
type2int(contract) -> 7;
type2int(trade) -> 8;
type2int(market) -> 9;
type2int(receipt) -> 10.

int2dump_name(1) -> accounts_dump;
%int2dump_name(2) -> exists_dump;
int2dump_name(3) -> oracles_dump;
int2dump_name(4) -> matched_dump;
int2dump_name(5) -> unmatched_dump;
int2dump_name(6) -> sub_accs_dump;
int2dump_name(7) -> contracts_dump;
int2dump_name(8) -> trades_dump;
int2dump_name(9) -> markets_dump;
int2dump_name(10) -> receipts_dump.



cs2v([]) -> [];
cs2v([A|T]) ->
    %converts consensus state into the verkle data.
    %consensus state is like accounts and contracts and whatever.
    %verkle data is a list of leaves that can be fed into store_verkle:batch/3.
    CFG = tree:cfg(amoveo),
    K = key(A),
    V = serialize(A),
    H = hash:doit(V),
    M1 = type2int(element(1, A)),
    DBName = int2dump_name(M1),
    M = dump:put(V, DBName),
    Meta = <<M1, M:(7*8)>>, 

    Leaf = leaf_verkle:new(K, H, Meta, CFG),
    [Leaf|cs2v(T)].
    

update_proof(L, ProofTree) ->
    %L is a list of accounts and contracts and whatever.
    CFG = tree:cfg(amoveo),
    Leaves = cs2v(L),

    verify_verkle:update(
      ProofTree, Leaves, CFG).

%recurse over the tree, and do cs2v on each leaf we find, to convert to the format we will write in the verkle tree.
store_verified(Loc, ProofTree) ->
    CFG = tree:cfg(amoveo),
    %io:fwrite(size(element(2, element(2, hd(hd(tl(ProofTree))))))), %32 bytes

    store_verkle:verified(
      Loc, ProofTree, CFG).

store_things(Things, Loc) ->
    %return the pointer to the new version of the verkle tree.
    CFG = tree:cfg(amoveo),
    V = cs2v(Things),
    %io:fwrite("store batch\n"),
    {P, _, _} = store_verkle:batch(V, Loc, CFG),
    P.
hash_key(accounts, Pub) ->
    key(#acc{pubkey = Pub});
hash_key(oracles, X) ->
    key(#oracle{id = X});
hash_key(N, X) -> 
    io:fwrite("hash key type "),
    io:fwrite(N),
    io:fwrite("\n"),
    X.

key({empty, K}) -> K;
key(#acc{pubkey = Pub}) ->
    %hash of the pubkey.
    PubkeySize = constants:pubkey_size(),
    case size(Pub) of
        PubkeySize ->
            hash:doit(compress_pub(Pub));
        33 -> hash:doit(Pub)
    end;
%key(#exist{hash = X}) ->
%    hash:doit(X);
key(#oracle{id = X}) ->
    hash:doit(<<X/binary, 0>>);
key(#matched{account = A, oracle = B}) ->
    A2 = compress_pub(A),
    hash:doit(<<A2/binary, B/binary, 0>>);
key(#unmatched{account = A, oracle = B}) ->
    A2 = compress_pub(A),
    hash:doit(<<A2/binary, B/binary, 1>>);
key(#sub_acc{pubkey = P, type = T, 
             contract_id = CID}) ->
    P2 = compress_pub(P),
    hash:doit(<<P2/binary, CID/binary, T:16>>);
key(#contract{code = C, many_types = MT, 
              source = S, source_type = ST}) ->
    hash:doit(<<C/binary, S/binary, MT:16, ST:16, 1>>);
key(#trade{value = V}) -> 
    hash:doit(<<V/binary, 1>>);
key(#market{id = X}) -> 
    hash:doit(<<X/binary, 2>>);
key(#receipt{id = X}) -> 
    hash:doit(<<X/binary, 3>>).


compress_pub(<<4, X:256, Y:256>>) ->
    Positive = Y rem 2,
    <<(6 + Positive), X:256>>;
compress_pub(<<4, X:256>>) ->
    <<4, X:256>>.

det_pow(A, 1) -> A;
det_pow(A, B) when B rem 2 == 0 -> 
    %io:fwrite("det pow even\n"),
    det_pow(A*A, B div 2);
det_pow(A, B) -> 
    A * det_pow(A, B-1).
det_pow_mod(A, 1, _) -> A;
det_pow_mod(A, B, P) when B rem 2 == 0-> 
    det_pow_mod(A*A rem P, B div 2, P);
det_pow_mod(A, B, P) -> 
    (A*det_pow_mod(A, B-1, P)) rem P.
decompress_pub(<<A, X:256>>) ->
    %y^2 = x^3 + 7
    %P = 2^256 - 2^32 - 2^9 - 2^8 - 2^7 - 2^6 - 2^4 - 1
    Positive = A - 6,
    P = det_pow(2, 256) - 
        det_pow(2, 32) -
        det_pow(2, 9) -
        det_pow(2, 8) -
        det_pow(2, 7) -
        det_pow(2, 6) -
        det_pow(2, 4) -
        1,
    X3 = ((X * X) rem P) * X rem P,
    Y2 = (X3 + 7) rem P,
    Y = det_pow_mod(Y2, (P + 1) div 4, P),
    if
        (Positive 
         bxor (Y rem 2)) == 0 -> 
            <<4, X:256, Y:256>>;
         true -> 
            NY = P -Y,
            <<4, X:256, NY:256>>
    end.
    
    
serialize(
  #acc{pubkey = Pub, nonce = Nonce, 
       balance = Balance}) ->
    %33 + 8 + 4 = 45 bytes.
    Pub2 = compress_pub(Pub),
    <<Pub2/binary, Balance:64, Nonce:32>>;
%serialize(#exist{hash = A, height = E}) ->
%    32 = size(A),
%    <<E:32, A/binary>>;%4 + 32 = 36
serialize(
  #oracle{id = ID, result = Result, question = Q,
          starts = S, type = T, creator = C, 
          done_timer = D
         }) ->
    %io:fwrite("serialize oracle\n"),
    32 = size(ID),
    32 = size(Q),
    C2 = compress_pub(C),
    <<ID/binary, Result, T, %32 + 1 + 1
      S:32, D:32, C2/binary,  %4 + 4 + 33
      Q/binary>>; %32
%64 + 10 + 33 = 107
serialize(
 #matched{account = A, oracle = O, true = T, 
          false = F, bad = B}) ->
    A2 = compress_pub(A),
    32 = size(O),
    <<A2/binary, O/binary, T:64, F:64, B:64>>;
%33 + 32 + 8 + 8 + 8 = 56+33 = 89
serialize(
 #unmatched{account = A, oracle = O, amount = M, 
            pointer = P}) ->
    A2 = compress_pub(A),
    32 = size(O),
    65 = size(P),
    <<A2/binary, O/binary, M:64, P/binary>>; 
%33 + 32 +8 + 65 = 41 + 64 + 33 = 138
serialize(
 #sub_acc{balance = B, nonce = N, pubkey = P, 
          contract_id = CID, type = T}) ->
    P2 = compress_pub(P),
    32 = size(CID),
    <<B:64, N:32, T:32, P2/binary, CID/binary>>;
%8 + 4 + 4 + 33 + 32 = 65 + 16 = 81
serialize(
  #contract{code = C, many_types = MT, nonce = Nonce, 
            last_modified = LM, delay = D, 
            closed = Closed, result = R, source = S, 
            source_type = ST, sink = Sink, volume = V
           }) ->
    32 = size(C),
    32 = size(R),
    32 = size(S),
    32 = size(Sink),
    <<C/binary, R/binary, S/binary, Sink/binary,
    ST:16, MT:16, Nonce:32, LM:32, D:32, Closed, 
      V:64>>;
%32*4 + 2 + 2 + 4 + 4 + 4 + 1 + 8
%128 + 16 + 9
%128 + 25 = 153
serialize(
  #trade{height = H, value = V}) ->
    32 = size(V),
    <<V/binary, H:32>>; %32 + 4 = 36
serialize(
  #market{id = I, cid1 = C1, type1 = T1, amount1 = A1,
          cid2 = C2, type2 = T2, amount2 = A2, 
          shares = S}) ->
    32 = size(I),
    32 = size(C1),
    32 = size(C2),
    <<I/binary, C1/binary, C2/binary, T1:16, T2:16,
    A1:64, A2:64, S:64>>;
%32 + 32 + 32 + 2 + 2+ 8 + 8 + 8
%96 + 28 = 124
serialize(
  #receipt{tid = T, pubkey = P, 
            nonce = N}) ->
    32 = size(T),
    P2 = compress_pub(P),
    <<T/binary, P2/binary, N:32>>.
%32 + 33 + 4 = 69


deserialize(1, 
  <<Pub:(33*8), Balance:64, Nonce:32>>) ->
    Pub2 = decompress_pub(<<Pub:(33*8)>>),
    #acc{pubkey = Pub2,
         nonce = Nonce, balance = Balance};
%deserialize(2, <<E:32, A:256>>) ->
%    #exist{hash = <<A:256>>, height = E};
deserialize(3, <<ID:256, Result, T, S:32, D:32,
                 C2:264, Q:256>>) ->
    C = decompress_pub(<<C2:264>>),
    #oracle{id = <<ID:256>>, result = Result,
            question = <<Q:256>>, starts = S,
            type = T, creator = C, done_timer = D};
deserialize(4, <<A:264, O:256, T:64, F:64, B:64>>) ->
    A2 = decompress_pub(<<A:264>>),
    #matched{account = A2, oracle = <<O:256>>, 
             true = T, false = F, bad = B};
deserialize(5, <<A:264, O:256, Am:64, P:256>>) ->
    A2 = decompress_pub(<<A:264>>),
    #unmatched{account = A2, oracle = <<O:256>>,
               amount = Am, pointer = <<P:256>>};
deserialize(6, <<B:64, N:32, T:32, P:264, CID:256>>) 
->
    P2 = decompress_pub(<<P:264>>),
    #sub_acc{balance = B, nonce = N, pubkey = P2,
             contract_id = CID, type = T};
deserialize(7, <<C:256, R:256, S:256, Sink:256,
                 ST:16, MT:16, Nonce:32, LM:32, D:32,
               Closed, V:64>>) ->
    #contract{code = <<C:256>>, result = <<R:256>>,
              source = <<S:256>>, sink = <<Sink:256>>,
              source_type = ST, many_types = MT,
              nonce = Nonce, last_modified = LM,
              delay = D, closed = Closed, volume = V};
deserialize(8, <<V:256, H:32>>) ->
    #trade{height = H, value = <<V:256>>};
deserialize(9, <<I:256, C1:256, C2:256, T1:16, T2:16,
                 A1:64, A2:64, S:64>>) ->
    #market{id = <<I:256>>, cid1 = <<C1:256>>,
            cid2 = <<C2:256>>, type1 = T1, type2 = T2,
            amount1 = A1, amount2 = A2, shares = S};
deserialize(10, <<T:256, P:264, N:32>>) ->
    P2 = decompress_pub(<<P:256>>),
    #receipt{tid = <<T:256>>, pubkey = P2, nonce = N};
%deserialize(_, T) when is_tuple(T) -> T;
deserialize(N, B) ->
    io:fwrite({N, B, size(B)}),
    1=2,
    ok.

    

to_keys([]) -> [];
to_keys([Acc|T]) ->
    [key(Acc)|to_keys(T)].

strip_tree_info([], R, D) -> {lists:reverse(R), D};
strip_tree_info([{Tree, X}|T], R, D) -> 
    %io:fwrite("strip tree info 2\n"),
    K = hash_key(Tree, X),
    %D2 = dict:store(K, Tree, D),
    D2 = dict:store(K, {Tree, X}, D),
    strip_tree_info(T, [K|R], D2);
strip_tree_info([H|T], R, D) -> 
    io:fwrite("strip tree info 3\n"),
    %io:fwrite({H}),
    1=2,
    strip_tree_info(T, [H|R], D).


remove_repeats([]) ->
    [];
remove_repeats([H|T]) ->
    B = is_in(H, T),
    if
        B -> remove_repeats(T);
        true -> [H|remove_repeats(T)]
    end.
is_in(X, []) -> false;
is_in(X, [X|_]) -> true;
is_in(X, [_|T]) -> 
    is_in(X, T).
    
    
get_proof(Keys, Loc) ->
    get_proof(Keys, Loc, small).
get_proof(Keys0, Loc, Type) ->
    {Keys3, TreesDict} = 
        strip_tree_info(Keys0, [], dict:new()),%this is where we lose the tree info. it also hashes the keys.
    Keys = remove_repeats(Keys3),%this is a N^2 algorithm, it might end up being the bottleneck eventually.
    CFG = tree:cfg(amoveo),
    case Type of
        fast -> ok;
        small -> ok
    end,
    lists:map(fun(X) -> 
                      S = size(X), 
                      if
                          (32 == S) -> ok;
                          true -> io:fwrite({Type, X, size(X)}) 
                      end
              end, Keys),
    {Proof, MetasDict} =
        get_verkle:batch(Keys, Loc, CFG, Type),
    %io:fwrite({Proof}),
    %order keys based on depth first scan of the tree from low to high.
    Keys30 = depth_order(Keys),
    %print_now(),
    %io:fwrite("key tree order \n"),
    if
        ?sanity ->
            Keys2 = key_tree_order(element(1, Proof)),
            KeyLengthBool = length(Keys) == length(Keys2),
            if
                KeyLengthBool -> ok;
                true ->
                    io:fwrite({length(Keys), length(Keys30),
                               Keys2, 
                               Keys30,
                               element(1, Proof), 
                               MetasDict}),
                    ok
            end;
        true -> ok
    end,
    Leaves = 
        lists:map(fun(K) ->
                          case dict:find(K, MetasDict) of
                              {ok, <<T, V:56>>} ->
                                  dump_get(T, V);
                              error ->
                                  {EmptyTree, UK} = 
                                      dict:fetch(K, TreesDict),
                                  %io:fwrite({EmptyTree, Keys0}),
                                  %{empty, K}
                                  true = is_binary(UK),
                                  {EmptyTree, UK}
                          end
                  end, Keys30),

    Proof2 = remove_leaves_proof(Proof),

    if
        not(?sanity) -> ok;
        true ->

            {Proof3, _} = 
                restore_leaves_proof(Proof2, Leaves),
            Proof4 = get_verkle:deserialize_proof(
                       get_verkle:serialize_proof(Proof3)),
    %checking that serializing doesn't beak anything.
            if
                not(Proof == Proof3) -> 
                    io:fwrite({element(1, Proof) == element(1, Proof3), element(1, Proof), element(1, Proof3)}),
                    1=2;
                not(Proof3 == Proof4) ->
                    io:fwrite("serialization issue\n"),
                    1=2;
                true -> ok
            end
    end,
    case Type of
        small -> 
            if
                not(?sanity) -> ok;
                true ->
                    io:fwrite("sanity check verkle proof\n"),
                    {true, _, _} = 
                        verify_verkle:proof(Proof, CFG)
            end,
            {get_verkle:serialize_proof(
                   Proof2), Leaves};
        fast -> 
            {Proof2, Leaves}
    end.
depth_order(Keys) ->
    K2 = lists:map(fun(K) ->
                           <<A:256/little>> = K,
                           <<B:256>> = 
                               <<A:256/big>>,
                           {K, B}
                   end, Keys),
    K3 = lists:sort(fun({K, B}, {K2, B2}) ->
                            B < B2
                    end, K2),
    lists:map(fun({K, _}) ->
                      K end, K3).
    
                      

remove_leaves_proof([]) -> [];
remove_leaves_proof({I, 0}) -> {I, 0};
remove_leaves_proof({I, {<<K:256>>, <<V:256>>}}) -> 
    {I, 1};
remove_leaves_proof(T) when is_tuple(T) -> 
    list_to_tuple(
      remove_leaves_proof(
        tuple_to_list(T)));
remove_leaves_proof([H|T]) -> 
    [remove_leaves_proof(H)|
     remove_leaves_proof(T)];
remove_leaves_proof(<<X:256>>) ->
    <<X:256>>;
remove_leaves_proof(N) when is_integer(N) -> N.


%todo. in restore_leaves_proof, sometimes there is an empty branch that stores 2 different leaves
restore_leaves_proof([], T) -> {[], T};
restore_leaves_proof([{I, 0}], T) -> 
    {[{I, 0}], T};
restore_leaves_proof(X, [{empty, K}|T]) -> 
    restore_leaves_proof(X, T);
restore_leaves_proof([{I, 1}], [L|T]) -> 
    K = key(L),
    case L of
        {empty, _} -> {[{I, 0}], T};
        _ -> 
            V = hash:doit(serialize(L)),
            {[{I, {K, V}}], T}
    end;
restore_leaves_proof(Proofs, Leaves) 
  when is_tuple(Proofs) -> 
    
    {Proofs2, Leaves2} = 
        restore_leaves_proof(
          tuple_to_list(Proofs), Leaves),
    {list_to_tuple(Proofs2), Leaves2};
restore_leaves_proof([H|T], L) -> 
    {H2, L2} = restore_leaves_proof(H, L),
    {T2, L3} = restore_leaves_proof(T, L2),
    {[H2|T2], L3};
restore_leaves_proof(<<X:256>>, L) ->
    {<<X:256>>, L};
restore_leaves_proof(X, L) when is_integer(X) ->
    {X, L}.

    


%only used in a sanity check, maybe we should delete this.
key_tree_order([]) -> [];
%key_tree_order({I, 0}) ->
%empty slot
%    [<<0:256>>];
key_tree_order({I, {<<K:256>>, <<V:256>>}}) 
  when is_integer(I) -> [<<K:256>>];
key_tree_order(T) when is_tuple(T) -> 
      key_tree_order(
        tuple_to_list(T));
key_tree_order([H|T]) -> 
    key_tree_order(H) ++ key_tree_order(T);
key_tree_order(<<X:256>>) -> [];
key_tree_order(I) when is_integer(I) -> [];
key_tree_order(X) -> 
    io:fwrite({X}),
    1=2.
    


dump_get(T, V) ->
    S = dump:get(V, int2dump_name(T)),
    deserialize(T, S).
    

verify_proof(Proof0, Things) ->
    CFG = tree:cfg(amoveo),
    
    Proof1 = get_verkle:deserialize_proof(Proof0),
    {Proof, []} = 
        restore_leaves_proof(Proof1, Things),

    CFG = tree:cfg(amoveo),
    {true, Leaves, ProofTree} = 
        verify_verkle:proof(Proof, CFG),
    %todo. in verify_verkle:proof, if there are 2 things stored in the same branch, and you try to make a proof of both of them, when you verify the proof, only one of the 2 things is included.
    %or maybe it is just missing leaves.


    %io:fwrite({Leaves}),
    Ks = to_keys(Things),
    Hs = lists:map(
           fun(A) -> 
                   case A of
                       {empty, _} -> 0;
                       _ ->
                           hash:doit(
                             serialize(A))
                   end
           end, Things),
    KHs = lists:zipwith(fun(K, H) -> {K, H} end,
                        Ks, Hs),
    %io:fwrite({Leaves, Ks}),
    %io:fwrite("starting what you need: \n"),
    %print_pairs(KHs),%this is missing an element if there are 2 things that start with the same first step in their paths. todo
    %io:fwrite("starting what you got: \n"),
    %print_pairs(Leaves),
    %io:fwrite("\n"),
    
    Bool = merge_same(KHs, Leaves),
    %io:fwrite(
    %{lists:sort(KHs), lists:sort(Leaves)}),
    %{lists:sort(KHs) == lists:sort(Leaves),
    {Bool, ProofTree}.
%verify_proof(Proof) ->
%    CFG = tree:cfg(amoveo),
%    Proof1 = get_verkle:deserialize_proof(Proof),
%    verify_verkle:proof(Proof1, CFG).

merge_same([], []) -> true;
merge_same([X|T1], %what we need
           T2 = [{D, X}|_] %what we got
          ) 
  when is_integer(D) ->
    %io:fwrite("merged same pair\n"),
    %io:fwrite(integer_to_list(size(term_to_binary([X|T1])))),
    %io:fwrite(" - "),
    %io:fwrite(integer_to_list(size(term_to_binary(T2)))),
    %io:fwrite("\n"),
    merge_same(T1, T2);%we leave the X in the got pile, because it is possible we still need to match more things with this leaf. This leaf is evidence that certain locations are empty.

%merge_same([X|T1], [X|T2]) ->
%    io:fwrite("merged same pair\n"),
%    merge_same(T1, T2);
merge_same([{Key, 0}|T1], %what you need.
           [{D, {LKey, Val}}|T2]) %what you got. 
  when is_integer(D) ->
    %io:fwrite("merged empty \n"),
    %io:fwrite(integer_to_list(size(term_to_binary(T1)))),
    %io:fwrite(" - "),
    %io:fwrite(integer_to_list(size(term_to_binary(T2)))),
    %io:fwrite("\n"),
    CFG = tree:cfg(amoveo),
    <<Key0:256>> = Key,
    Key2 = leaf_verkle:path_maker(Key0, CFG),

    <<LKey0:256>> = LKey,
    LKey2 = leaf_verkle:path_maker(LKey0, CFG),

    false = Key == LKey,
    SSD = starts_same_depth(Key2, LKey2, D),
    case SSD of
        true -> 
            merge_same(T1, [{D, {LKey, Val}}|T2]);
        skip -> 
            %maybe this leaf was already used, or we aren't using it. lets continue.
            merge_same([{Key, 0}|T1], T2);
        false -> 
            <<_:240, SecondKey, FirstKey>> = Key,
            <<_:240, SecondLKey, FirstLKey>> = LKey,
            %<<_:240, SecondT2, FirstT2>> = element(1, element(2, hd(T2))),
            <<_:240, SecondT1, FirstT1>> = 
                case T1 of
                    [] -> <<0:256>>;
                    _ -> element(1, hd(T1)) 
                end,
            io:fwrite(
              {D, {need, {FirstKey, SecondKey}}, 
               {got, {FirstLKey, SecondLKey}},
               {next_need, {FirstT1, SecondT1}},
               %{next_got, {FirstT2, SecondT2}}
               {next_got, T2}}),
            1=2
    end;
merge_same([{Key, 0}|T1], [{Branch, 0}|T2]) ->
    %if doesn't match branch, recurse to see if it matches the next branch.
    %if it does match, keep the branch to see if more match.
    %io:fwrite("empty empty\n"),
    %io:fwrite(integer_to_list(length(T1))),
    %io:fwrite(" - "),
    %io:fwrite(integer_to_list(length(T2))),
    %io:fwrite("\n"),
    CFG = tree:cfg(amoveo),
    <<Key0:256>> = Key,
    Key2 = leaf_verkle:path_maker(Key0, CFG),
    Bool = starts_same(Key2, lists:reverse(Branch)),
    if
        Bool -> 
            %io:fwrite("merged empty 2\n"),
            merge_same(T1, [{Branch, 0}|T2]);
        true -> 
            %io:fwrite("nothing left to match with this branch 2 --  "),
            %print_empty_branch(Branch),
            <<K1>> = hd(Key2),
            <<K2>> = hd(tl(Key2)),
            %io:fwrite(" %% "),
            %io:fwrite(integer_to_list(K1)),
            %io:fwrite(" "),
            %io:fwrite(integer_to_list(K2)),
            %io:fwrite("\n"),
            %io:fwrite("branch length "),
            %io:fwrite(integer_to_list(length(Branch))),
            %io:fwrite("\n"),
            merge_same([{Key, 0}|T1], T2)
    end;
%merge_same([{_, 0}], []) -> true;
merge_same(X, [{Branch, 0}|T2]) ->
    %nothing left to match with this branch.
    %io:fwrite("nothing left to match with this branch\n"),
    %io:fwrite(integer_to_list(length(X))),
    %io:fwrite(" - "),
    %io:fwrite(integer_to_list(length(T2))),
    %io:fwrite("\n"),
    merge_same(X, T2);
merge_same(X, [{D, {K, V}}|T2]) 
  when is_integer(D) and 
       is_binary(K) and 
       is_binary(V) and 
       (32 == size(K)) and 
       (32 == size(V)) ->
    %io:fwrite("nothing left to match with this leaf\n"),%maybe was used to show that a branch is empty.
    %io:fwrite(integer_to_list(length(X))),
    %io:fwrite(" - "),
    %io:fwrite(integer_to_list(length(T2))),
    %io:fwrite("\n"),
    merge_same(X, T2);
merge_same(A, B) -> 
    io:fwrite("what you need: \n"),
    print_pairs(A),
    io:fwrite("what you got: \n"),
    print_pairs(B),
    B2 = case B of
             [] -> [[]];
             _ -> B
         end,
    io:fwrite({hd(A), hd(B2), length(A), length(B)}),
    1=2,
    false.

print_pairs([]) -> 
    io:fwrite("finished print pairs"),
    io:fwrite("\n"),
    ok;
print_pairs([{<<_:232, Z, Y, X>>, _}|T]) -> 
    io:fwrite("key starts with: "),
    io:fwrite(integer_to_list(X)),
    io:fwrite(" "),
    io:fwrite(integer_to_list(Y)),
    io:fwrite(" "),
    io:fwrite(integer_to_list(Z)),
    io:fwrite("\n"),
    print_pairs(T);
print_pairs([{D, {<<_:232, Z, Y, X>>, _}}|T]) -> 
    io:fwrite("key starts with: "),
    io:fwrite(integer_to_list(X)),
    io:fwrite(" "),
    io:fwrite(integer_to_list(Y)),
    io:fwrite(" "),
    io:fwrite(integer_to_list(Z)),
    io:fwrite(" depth: "),
    io:fwrite(integer_to_list(D)),
    io:fwrite("\n"),
    print_pairs(T);
print_pairs([{L = [_|_], _}|T]) -> 
    io:fwrite("empty branch: "),
    print_empty_branch(L),
    io:fwrite("\n"),
    print_pairs(T).
print_empty_branch([]) -> ok;
print_empty_branch([H|T]) ->
    print_empty_branch(T),
    io:fwrite(integer_to_list(H)),
    io:fwrite(" ").
    
                   
    


starts_same(_, []) -> true;
starts_same([<<X>>|T], [X|T2]) ->
    starts_same(T, T2);
starts_same(_, _) -> false.

starts_same_depth(_, _, 0) -> true;
starts_same_depth([<<X>>|T1], [<<X>>|T2], D) ->
    %io:fwrite("starts same depth "),
    %io:fwrite(integer_to_list(X)),
    %io:fwrite("\n"),
    starts_same_depth(T1, T2, D-1);
starts_same_depth([<<A>>|_], [<<B>>|_], C) -> 
    %io:fwrite({hd(A), hd(B), length(A), length(B), C}),
    if
        (B < A) -> skip;
        true -> false
    end.





prune(Trash, Keep) ->
    CFG = tree:cfg(amoveo),
    RemovedLeaves = 
        prune_verkle:doit_stem(Trash, Keep, CFG),
    lists:map(fun(L = {leaf, _Key, _Value, Meta}) ->
                      delete_thing(Meta)
              end, RemovedLeaves),
    ok.
delete_thing(<<X, Loc:56>>) ->
    DBname = int2dump_name(X),
    dump:delete(Loc, DBname).

merkle2verkle(
  Tree = #trees5{
     accounts = A, channels = _C, existence = _E, 
     oracles = O, governance = _G, matched = M,
     unmatched = U, sub_accounts = SA, contracts = CO,
     trades = T, markets = M2, receipts = R}, 
  Loc) ->
    Types = [accounts, oracles, matched, unmatched, sub_accounts, contracts, trades, markets, receipts],
    TypePairs = lists:zipwith(
                  fun(A, B) -> {A, B} end,
                  Types,
                  [A, O, M, U, SA, CO, T, M2, R]),
    AllLeaves = lists:foldl(
      fun({Type, X}, A) ->
              Leaves = 
                  lists:map(
                    fun(F) -> 
                            (Type):deserialize(leaf:value(F)) end,
                    trie:get_all(X, Type)),
              A ++ Leaves
      end, [], TypePairs),
    %io:fwrite(AllLeaves),
    store_things(AllLeaves, Loc).
    

test(0) ->
    %testing the raw verkle tree interface. only stores keys and values of 32 bytes.
    CFG = tree:cfg(amoveo),
    Loc = 1,
    Many = 4,
    Pairs = 
        lists:map(
          fun(N) ->
                  Key = crypto:strong_rand_bytes(32),
                  Val = crypto:strong_rand_bytes(32),
                  Meta = crypto:strong_rand_bytes(8),
                  {Key, Val, Meta}
          end, range(1, 4)),
    Leaves = lists:map(
               fun({Key, Val, Meta}) ->
                       leaf_verkle:new(
                         Key, Val, Meta, CFG)
               end, Pairs), 
    AddKey = <<1:256>>,
    Keys0 = lists:map(
             fun({Key, _, _}) ->
                     Key
             end, Pairs),
    Keys = [AddKey| Keys0],
    
    {Loc2, stem, _} = store_verkle:batch(
                        Leaves, Loc, CFG),

    %normal proof has ~500 bytes overhead. Take ~1 second longer to make that fast proofs.
    {Proof, _} = get_verkle:batch(Keys, Loc2, CFG),
    %fast proof has ~8000 bytes overhead, but can be made faster.
    {FastProof, _} = 
        get_verkle:batch(Keys, Loc2, CFG, fast),

    %verifying proofs
    Root = stem_verkle:root(
             stem_verkle:get(Loc2, CFG)),
    {ProofTree1, _Commit1, _Opening1} = Proof,
    {ProofTree2, _, _} = FastProof,
    Root01 = stem_verkle:hash_point(hd(ed:decompress_points([hd(ProofTree1)]))),
    Root01 = stem_verkle:hash_point(hd(ed:decompress_points([hd(ProofTree2)]))),
    Root01 = stem_verkle:hash_point(Root),
    {true, Leaves2, ProofTree3} = 
        verify_verkle:proof(Proof, CFG),
    {true, Leaves2, ProofTree3} = 
        verify_verkle:proof(FastProof, CFG),

    %updating a proof
    AddLeaf = leaf_verkle:new(
                AddKey, <<27, 0:248>>, <<1:64>>, 
                CFG),
    UpdateLeaf = leaf_verkle:new(
                   element(1, hd(Pairs)),
                   <<28, 0:248>>, <<2:64>>, CFG),
    DeleteLeaf = {element(1, hd(tl(Pairs))),
                  0},
    ProofTree4 = 
        verify_verkle:update(
          ProofTree3, 
          [AddLeaf, UpdateLeaf, DeleteLeaf], 
          CFG),
    %new root of new tree:
    Root2 = stem_verkle:hash_point(hd(ProofTree4)),
    
    %efficiently update the hard drive with the new version. Faster that writing the leaves in a batch, because pedersen commitments are already computed.
    Loc3 = store_verkle:verified(
             Loc2, ProofTree4, CFG),

    Pruned = prune_verkle:doit_stem(Loc2, Loc3, CFG),
    %io:fwrite(Pruned),
    %{leaf, Key, Value, Meta}) ->

    success;
test(1) ->
    %testing making and verifying the verkle proof.
    
    Range = 2,
    Keys = lists:map(fun(_) -> signing:new_key()
                     end, range(1, Range)),
    As = lists:map(
           fun({P, _}) ->
                   #acc{pubkey = P, 
                        balance = 100000000, 
                        nonce = 0} 
           end, Keys),
    {As0, _} = lists:split(Range div 2, As),

    As2 = lists:map(fun(A) ->
                            A#acc{balance = 27}
                    end, As0),
    
    Loc = 1,
    Loc2 = store_things(As, Loc),
    
    {Proof, As0b} = get_proof(to_keys(As2), Loc2),
%make sure in and out are same length!! todo

    {true, ProofTree} = verify_proof(Proof, As0b),
    
    ProofTree2 = 
        update_proof(As2, ProofTree),
   % io:fwrite(ProofTree2),
    
    Loc3 = store_verified(Loc2, ProofTree2),

    {Proof3, As2b} = get_proof(to_keys(As2), Loc3),
    
    {true, V2} = verify_proof(Proof3, As2b),

    prune(Loc2, Loc3),

    %io:fwrite({hd(Stuff), hd(Stuff2)}),
    %io:fwrite(As2),

    success;
test(2) ->
    %testing pubkey compression.
    {Pub, _} =  signing:new_key(),
    Cpub = compress_pub(Pub),
    Pub2 = decompress_pub(Cpub),
    <<_, _:256, Y1:256>> = Pub,
    <<_, _:256, Y2:256>> = Pub2,
    %io:fwrite({Y1, Y2}),
    Y1 = Y2,
    success;
test(3) ->
    %testing converting the merkle stuff to verkle stuff.
    {Pub0, _Priv} = signing:new_key(),
    Pub0c = compress_pub(Pub0),
    Acc0 = accounts:new(Pub0, 1000027),
    Empty = 1,
    A = accounts:write(Acc0, Empty),

    Start = 5,
    QuestionText = <<"question text">>,
    ID = oracle_new_tx:id_generator2(Start, 0, 0, QuestionText),
    Oracle0 = 
        oracles:new(
          ID, hash:doit(QuestionText), Start, Pub0, 
          0, 0, dict:new(), true, forks:get(52) + 10),
    O = oracles:write(Oracle0, Empty),

    Matched0 = matched:new(Pub0, ID, 1, 1000),
    M = matched:write(Matched0, Empty),

    Unmatched0 = unmatched:new(Pub0, ID, 2000),
    U = unmatched:write(Unmatched0, Empty),

    C0 = contracts:new(hash:doit(<<>>), 2),
    CID = contracts:make_id(C0),
    C = contracts:write(C0, Empty),

    SA0 = sub_accounts:new(Pub0, 1000029, CID, 1),
    SA = sub_accounts:write(SA0, Empty),

    Trade0 = trades:new(104, hash:doit(<<>>)),
    Tr = trades:write(Trade0, Empty),

    Market0 = markets:new(CID, 1, 10005, CID, 2, 10006),
    M = markets:write(Market0, Empty),

    Receipt0 = receipts:new(hash:doit(<<>>), Pub0, 1),
    R = receipts:write(Receipt0, Empty),

    T = #trees5{
      accounts = A, 
      oracles = O, 
      matched = M,
      unmatched = U, sub_accounts = SA,
      contracts = C, trades = Tr, 
      markets = M, receipts = R},
    V = merkle2verkle(T, 1),
    success;
test(4) ->
    %testing proofs of the non-existence of things.
    Many = 8000,
    Keys = lists:map(fun(_) -> signing:new_key()
                     end, range(1, Many)),
    As = lists:map(
           fun({P, _}) ->
                   #acc{pubkey = P, 
                        balance = 100000000, 
                        nonce = 0} 
           end, Keys),
    Loc = 1,
    {As0, As1} = lists:split(Many div 2, As),
    print_now(),
    io:fwrite("store things \n"),
    Loc2 = store_things(As1, Loc),
    %As0_1 = [hd(As0)] ++ As1,
    As0_1 = As,
    Keys2 = to_keys(As0_1),
    print_now(),
    io:fwrite("get proof\n"),
    {Proof, As2} = 
        get_proof(Keys2, Loc2),
    true = length(As2) == length(As0_1),
    print_now(),
    io:fwrite("things proved "),
    io:fwrite(integer_to_list(length(As2))),
    io:fwrite("\n"),
    print_now(),
    io:fwrite("verify proof\n"),
    {true, ProofTree} = 
        verify_proof(Proof, As2),
    As3 = lists:map(fun(A) ->
                            A#acc{balance = 28}
                    end, As0_1),
    print_now(),
    io:fwrite("update proof\n"),
    ProofTree2 = update_proof(As3, ProofTree),
    print_now(),
    io:fwrite("store new\n"),
    Loc3 = store_verified(Loc2, ProofTree2),
    print_now(),
    io:fwrite("get proof 2\n"),
    %io:fwrite({to_keys(As2)}),
    {Proof3, As2b} = get_proof(to_keys(As2), Loc3),
    print_now(),
    io:fwrite("verify proof 2\n"),
    %{true, V2} = verify_proof(Proof3, As3),
    {true, V2} = verify_proof(Proof3, As2b),
    prune(Loc2, Loc3),
    success.

    
print_now() ->    
    {_, A, B} = erlang:timestamp(),
    B2 = B div 100000,
    io:fwrite(integer_to_list(A)),
    io:fwrite("."),
    io:fwrite(integer_to_list(B2)),
    io:fwrite(" "),
    ok.
    




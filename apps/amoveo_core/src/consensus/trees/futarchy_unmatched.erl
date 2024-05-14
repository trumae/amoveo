-module(futarchy_unmatched).
-export([key_to_int/1, make_id/2, dict_get/2,
         dict_write/2, dict_write/3, dict_get/3,
         id_pair/2
        ]).
-include("../../records.hrl").
key_to_int(#futarchy_unmatched{id = <<X:256>>}) -> X;
key_to_int(<<X:256>>) -> X.
make_id(FU = #futarchy_unmatched{
          owner = Pub,
          futarchy_id = FID,
          decision = Decision,
          goal = Goal,
          limit_price = LP,
          revert_amount = Amount
         }, _Height) ->
    Pub2 = case size(Pub) of
               33 -> Pub;
               65 -> trees2:compress_pub(Pub)
           end,
    true = is_integer(LP),
    true = is_integer(Amount),
    case Goal of
        0 -> ok;
        1 -> ok
    end,
    case Decision of
        0 -> ok;
        1 -> ok
    end,
    B = <<Pub2/binary, FID/binary, Decision, Goal, LP:64, Amount:64>>,
    ID = hash:doit(B),
    FU#futarchy_unmatched{id = ID}.

dict_get(ID, Dict, _) ->
    dict_get(ID, Dict).
dict_get(ID, Dict) ->
    case csc:read({?MODULE, ID}, Dict) of
        error -> error;
        {empty, _, _} -> empty;
        {ok, ?MODULE, Val} -> Val
    end.
dict_write(Job, Dict) ->
    dict_write(Job, 0, Dict).
dict_write(Job, _Meta, Dict) ->
    ID = Job#futarchy_unmatched.id,
    csc:update({?MODULE, ID}, Job, Dict).

      
%given an order, we need to calculate where in the order book this order will be placed.
%Return the id of the order ahead of it, and behind it, in the book. 
id_pair(Price, 
        Pointer %points to the next element in the linked list.
       ) ->
    io:fwrite("futarchy_unmatched id_pair\n"),
    case trees:get(futarchy_unmatched, Pointer) of
        empty -> {<<0:256>>, <<0:256>>};
        FU ->
            #futarchy_unmatched{ 
          limit_price = L,
          id = ID,
          behind = Next
         } = FU,
            if
                (Price > L) -> {<<0:256>>, <<ID/binary>>};%you are at the front of the line.
                true -> id_pair2(Price, ID, Next)
            end
    end.
id_pair2(Price, Previous, Pointer) ->
    case trees:get(futarchy_unmatched, Pointer) of
        empty -> {Previous, <<0:256>>};%you are at the back of the line.
        FU ->
            #futarchy_unmatched{ 
          limit_price = L,
          id = ID,
          behind = Next
         } = FU,
            if
                (Price > L) -> {Previous, ID};
                true -> id_pair2(Price, ID, Next)
            end
    end.
                    

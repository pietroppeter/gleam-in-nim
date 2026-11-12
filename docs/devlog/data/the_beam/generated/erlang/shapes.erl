-module(shapes).
-compile([no_auto_import, nowarn_ignored, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-export([area/1, describe/1, widen/2, parse/2, total_area/1, greeting/1, make_adder/1, safe_divide/2, header/1, not_yet/0]).
-export_type([shape/0, parse_error/0]).
-moduledoc(~" A tiny module that touches most of what the code generator has to handle.").

-type shape() :: {circle, float()} | {rectangle, float(), float()} | dot.

-type parse_error() :: {unknown_shape, binary()} | bad_number.

-spec area(shape()) -> float().
-doc(~" Area of a shape. Pattern matching on a custom type.").
area(Shape) ->
    case Shape of
        {circle, R} ->
            (3.14159 * R) * R;

        {rectangle, W, H} ->
            W * H;

        dot ->
            +0.0
    end.

-spec describe(shape()) -> binary().
describe(Shape) ->
    case Shape of
        {circle, _} ->
            ~"circle";

        {rectangle, W, H} when W =:= H ->
            ~"square";

        {rectangle, _, _} ->
            ~"rectangle";

        dot ->
            ~"dot"
    end.

-spec widen(shape(), float()) -> shape().
widen(Shape, By) ->
    case Shape of
        {rectangle, _, _} = R ->
            {rectangle, erlang:element(2, R) + By, erlang:element(3, R)};

        Other ->
            Other
    end.

-spec parse(binary(), binary()) -> {ok, shape()} | {error, parse_error()}.
parse(Name, Size) ->
    gleam@result:'try'(begin
        _pipe = gleam_stdlib:parse_int(Size),
        gleam@result:replace_error(_pipe, bad_number)
    end, fun(N) ->
        Size@1 = erlang:float(N),
        case Name of
            ~"circle" ->
                {ok, {circle, Size@1}};

            ~"square" ->
                {ok, {rectangle, Size@1, Size@1}};

            ~"dot" ->
                {ok, dot};

            _ ->
                {error, {unknown_shape, Name}}
        end
    end).

-spec sum(list(float()), float()) -> float().
sum(Numbers, Acc) ->
    case Numbers of
        [] ->
            Acc;

        [First | Rest] ->
            sum(Rest, Acc + First)
    end.

-spec total_area(list(shape())) -> float().
total_area(Shapes) ->
    _pipe = Shapes,
    _pipe@1 = gleam@list:map(_pipe, fun area/1),
    sum(_pipe@1, +0.0).

-spec greeting(binary()) -> binary().
greeting(Name) ->
    case [<<Name/binary, "!"/utf8>>, ~"unused"] of
        [First | _] ->
            <<"Hello, "/utf8, First/binary>>;

        _value ->
            erlang:error(#{
                gleam_error => let_assert,
                message => ~"Pattern match failed, no pattern matched the value.",
                file => ~"src/shapes.gleam",
                module => ~"shapes",
                function => ~"greeting",
                line => 70,
                value => _value,
                start => 1485,
                'end' => 1533,
                pattern_start => 1496,
                pattern_end => 1507
            })
    end.

-spec make_adder(integer()) -> fun((integer()) -> integer()).
make_adder(N) ->
    fun(X) ->
        X + N
    end.

-spec safe_divide(integer(), integer()) -> integer().
safe_divide(A, B) ->
    case B of
        0 ->
            0;

        _value ->
            A div _value
    end.

-spec header(bitstring()) -> {ok, {integer(), bitstring()}} | {error, nil}.
header(Bytes) ->
    case Bytes of
        <<Version:8, Rest/binary>> ->
            {ok, {Version, Rest}};

        _ ->
            {error, nil}
    end.

-spec not_yet() -> integer().
not_yet() ->
    erlang:error(#{
        gleam_error => todo,
        message => ~"write me",
        file => ~"src/shapes.gleam",
        module => ~"shapes",
        function => ~"not_yet",
        line => 90
    }).


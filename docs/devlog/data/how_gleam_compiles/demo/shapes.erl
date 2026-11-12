-module(shapes).
-compile([no_auto_import, nowarn_ignored, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-export([area/1]).
-export_type([shape/0]).

-type shape() :: {circle, float()} | {rectangle, float(), float()}.

-spec area(shape()) -> float().
area(Shape) ->
    case Shape of
        {circle, Radius} ->
            (3.14 * Radius) * Radius;

        {rectangle, Width, Height} ->
            Width * Height
    end.


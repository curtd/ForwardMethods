const arg_placeholder = :_
const obj_placeholder = :_obj

function arg_from_type_sig(expr)
    @switch expr begin 
        @case :($x::$T)
            return x 
        @case :($x = $y)
            return x 
        @case _ 
            return expr 
    end
end

function matches_type_signature(T, UnionallType, expr)
    @switch expr begin 
        @case Expr(:(::), arg, S) && if S == T end
            return (; matches=true, unionall=false, type=false, arg)
        @case (Expr(:(::), arg, Expr(:curly, :Type, S)) && if S == T end) || Expr(:(::), Expr(:curly, :Type, S)) && if S == T end
            return (; matches=true, unionall=false, type=true, arg=T)
            return (; matches=true, unionall=false, type=true, arg=T)
        @case Expr(:(::), arg, S) && if S == UnionallType end
            return (; matches=true, unionall=true, type=false, arg)
        @case (Expr(:(::), arg, Expr(:curly, :Type, S)) && if S == UnionallType end) || Expr(:(::), Expr(:curly, :Type, S)) && if S == UnionallType end
            return (; matches=true, unionall=true, type=true, arg=UnionallType) 
        @case _ 
            return (; matches=false)
    end
end

struct FieldFuncExprs 
    arg_func
    type_func
end

function forward_method_signature(Type, field_funcs::FieldFuncExprs, map_func::Function, input; _sourceinfo=nothing)
    (func_expr, whereparams) = @switch input begin 
        @case Expr(:where, func, params...) 
            (func, params)
        @case _ 
            (input, nothing)    
    end
    if is_unionall_type(Type)
        UnionallType, _ = union_all_type_and_param(Type)
    else
        UnionallType = Type 
    end
    (funcname, args, kwargs) = @switch func_expr begin 
        @case Expr(:call, funcname, Expr(:parameters, kwargs...), args...)
            (funcname, args, kwargs)
        @case Expr(:call, funcname, args...)
            (funcname, args, [])
        @case ::Symbol || :($A.$f) 
            t = gensym(arg_placeholder)
            S = isnothing(whereparams) ? UnionallType : Type
            (func_expr, [object_argument(t, S)], [])        
        @case _ 
            error("Unrecognized expression method (= $func_expr) -- expected expression to be of the form f(args), f(args; kwargs)")
    end
    
    found_arg_local_name = gensym("child_value")
    found = false
    local found_input_arg
    local found_arg
    local found_arg_expr
    found_arg_is_type = false
    input_args = []
    output_args = []
    for arg in args 
        if arg === arg_placeholder
            matched_arg = gensym(arg_placeholder)
            if isnothing(whereparams)
                push!(input_args, object_argument(matched_arg, UnionallType))
            else
                push!(input_args, object_argument(matched_arg, Type))
            end
            found_input_arg = matched_arg
            found_arg = field_funcs.arg_func(matched_arg)
        elseif (_matches = matches_type_signature(Type, UnionallType, arg); _matches.matches)
            matched_arg = _matches.arg 
            if _matches.type 
                found_input_arg = _matches.unionall ? UnionallType : Type
                push!(input_args, type_argument(matched_arg))
                
                isnothing(field_funcs.type_func) && error("Must forward methods with `Type{$Type}` signatures via `getfield` ")
                found_arg = field_funcs.type_func(matched_arg)
                found_arg_is_type = true
            else
                found_input_arg = matched_arg
                push!(input_args, arg)
                found_arg = field_funcs.arg_func(matched_arg)
            end
        else 
            # Non-matching arguments, just forward argument names
            push!(input_args, arg)

            push!(output_args, arg_from_type_sig(arg))
            continue 
        end

        found && error("Cannot have multiple arguments matching type $Type in input = `$input`")
        found_arg_expr = :(local $found_arg_local_name = $found_arg)
        push!(output_args, found_arg_local_name)
        found = true
    end
    if !found
        error("No argument matching type $Type in input = `$input`")
    end
    func_body = Expr(:call, funcname)
    if !isempty(kwargs)
        push!(func_body.args, Expr(:parameters, kwargs...))
    end
    push!(func_body.args, output_args...)
    body_block = Expr(:block)
    if !isnothing(_sourceinfo)
        push!(body_block.args, _sourceinfo)
    end
    push!(body_block.args, found_arg_expr)
    mapped_body = !found_arg_is_type ? map_func(found_input_arg, func_body) : func_body
    push!(body_block.args, mapped_body)

    new_sig = Expr(:call, funcname)
    if !isempty(kwargs)
        push!(new_sig.args, Expr(:parameters, kwargs...))
    end
    push!(new_sig.args, input_args...)
    if !isnothing(whereparams)
        new_sig = Expr(:where, new_sig, whereparams...)
    end
    func_def = Expr(:(=), new_sig, body_block)
    return func_def
end

forward_method_signature(Type, field_funcs, input; kwargs...) = forward_method_signature(Type, field_funcs, identity_map_expr, input; kwargs...)

function nested_dotted_field_arg_expr(field_expr, input)
    @switch field_expr begin 
        @case ::Symbol
            return Expr(:call, :(Base.getfield), input, QuoteNode(field_expr))
        @case ::QuoteNode && if (field_expr.value isa Symbol) end
            return nested_dotted_field_arg_expr(field_expr.value, input)
        @case Expr(:., lhs, rhs)
            arg_expr = nested_dotted_field_arg_expr(lhs, input)
            return Expr(:call, :(Base.getfield), arg_expr, rhs)
        @case _ 
            error("Invalid nested dotted expression $field_expr")
    end
end

function nested_dotted_field_type_expr(field_expr, input)
    @switch field_expr begin 
        @case ::Symbol
            return Expr(:call, :(Base.fieldtype), input, QuoteNode(field_expr))
        @case ::QuoteNode && if (field_expr.value isa Symbol) end
            return nested_dotted_field_type_expr(field_expr.value, input)
        @case Expr(:., lhs, rhs)
            arg_expr = nested_dotted_field_type_expr(lhs, input)
            return Expr(:call, :(Base.fieldtype), arg_expr, rhs)
        @case _ 
            error("Invalid nested dotted expression $field_expr")
    end
end
function nested_dotted_field_arg_func(value) 
    return let value=value
        (t)->nested_dotted_field_arg_expr(value, t)
    end
end
function nested_dotted_field_type_func(value) 
    return let value=value
        (t)->nested_dotted_field_type_expr(value, t)
    end
end

function FieldFuncExprs(value)
    f = @switch value begin 
            @case ::Symbol || Expr(:., arg1, arg2, args...)
                (nested_dotted_field_arg_func(value), nested_dotted_field_type_func(value))
            @case ::QuoteNode && if value.value isa Symbol end
                FieldFuncExprs(value.value)
            @case Expr(:ref, arg1, args...)
                (replace_first_arg_in_call_func(value), nothing)
            @case Expr(:call, func, arg1, arg2) 
                if func in (:getproperty, :(Base.getproperty)) && arg2 isa QuoteNode
                    (replace_first_arg_in_call_func(Expr(:call, :(Base.getproperty), arg1, arg2)), nothing)
                elseif func in (:getfield, :(Base.getfield)) && arg2 isa QuoteNode 
                    (nested_dotted_field_arg_func(arg2), nested_dotted_field_type_func(arg2))
                elseif func in (:getindex, :(Base.getindex)) && arg2 isa QuoteNode 
                    (replace_first_arg_in_call_func(Expr(:call, :(Base.getindex), arg1, arg2)), nothing)
                else 
                    @goto error
                end
            @case Expr(:call, func, arg1)
                (replace_first_arg_in_call_func(value), nothing)
            @case _ 
                @goto error
    end
    if f isa FieldFuncExprs
        return f 
    else
        arg_func, type_func = f
        return FieldFuncExprs(arg_func, type_func)
    end
    @label error 
    error("Invalid field expression `$value`")
end

function parse_field(field)
    @switch field begin 
        @case Expr(:(=), :field, value) 
            return FieldFuncExprs(value)
        @case _ 
            @goto error 
    end
    @label error 
    error("Invalid field expression `$field`")               
end

function forward_methods_expr(Type, field_expr, args...; _sourceinfo=nothing)
    field_funcs = parse_field(field_expr)
    !isempty(args) || error("Input arguments must be nonempty")
    firstarg, rest = Iterators.peel(args)
    if (map_func = parse_map_expr(firstarg); !isnothing(map_func))
        method_exprs = rest 
    else
        map_func = identity_map_expr
        method_exprs = args 
    end

    output = Expr(:block)
    for arg in method_exprs
        _args = @switch arg begin 
            @case Expr(:block, args...)
                filter(t->!(t isa LineNumberNode), args)
            @case _ 
                [arg]
        end
        for arg in _args
            push!(output.args, forward_method_signature(Type, field_funcs, map_func, arg; _sourceinfo))
        end
    end
    return output
end

"""
    @forward_methods T [field=_field] [map=_map] methods... 

Forwards the method definitions for `x::T`, depending on the value of `_field`. 

`_field` must be one of the following expressions
- `k::Symbol` or `k::QuoteNode`, or an expression of the form `getfield(_, k)`, in which case methods will be forwarded to `getfield(x, k)`
- an expression of the form `a.b.c. ...`, in which case methods will be forwarded to `getfield(getfield(getfield(x, :a), :b), :c) ...`
- an expression of the form `getproperty(_, k)`, in which case methods will be forwarded to `getproperty(x, k)`
- an expression of the form `t[args...]`, in which case methods will be forwarded to `x[args...]`
- or an expression of the form `f(_)` for a single-argument function `f`, in which case methods will be forwarded to `f(x)`

For notational purposes below, call the forwarded value `forwarded_value(x)`. 

Each `method` must be one of the following expressions 
- an expression of the form `f::Symbol` or `A.f`, which will forward the single-argument function `f(x)` or `A.f(x)` to `f(forwarded_value(x))` or `A.f(forwarded_value(x))`, respectively

- a function signature of the form `f(args...)`, or `f(args...; kwargs...)`. In this form, there must be either exactly one expression of 
  the form `x::T` or `_` (an underscore) in `args`. If this occurs at position `i`, say, this macro will forward this method to the definition
  
    `f(args[1], args[2], ..., args[i-1], forwarded_value(x), args[i+1], ..., args[end]; kwargs...)`

  When `field` maps to invoking `getfield` for field `k`, one can also write an argument expression of the form `::T` or `x::T`. In this case, this macro definition will define
  
    `f(args[1], ..., args[i-1], ::Type{T}, args[i+1], ..., args[end]; kwargs) = f(args[1], ..., args[i-1], fieldtype(T, k), args[i+1], ..., args[end]; kwargs)`

  which can be useful for forwarding, for instance, trait-based methods to the corresponding container type. 

Each `method` may also be a `:block` expression, where each sub-expression satisfies one of the above conditions

## Optional Arguments 
The optional `map=_map` parameter allows you to apply an expression transformation to the resulting forwarded expression. `_map` must be an expression containing at least one underscore `_` placeholder and optionally `_obj` placeholders. `_` and `_obj` will be replaced with the transformed function and initial object argument, respectively. 

For example, if we have 
```julia 
    struct LockableDict{K,V}
        d::Dict{K,V}
        lock::ReentrantLock
    end
    @forward LockableDict{K,V} field=lock Base.lock Base.unlock
    @forward LockableDict{K,V} field=d map=(begin lock(_obj); try _ finally unlock(_obj) end end) Base.getindex(_, k) 
```
Then the expressions generated in the second statement are (roughly) of the form 

```julia 
    function Base.getindex(l::LockableDict{K,V}, k)
        lock(l)
        try 
            Base.getindex(getfield(l, :d))
        finally
            unlock(l)
        end
    end
```


# Notes
- Parametric expressions are supported for `T`, as well as for the function signature form of `method`

# Examples
```julia-repl
julia> struct B{T} 
         v::Vector{T}
       end

julia> @forward_methods B{T} field=v Base.firstindex Base.lastindex Base.getindex(_, k::Int) Base.setindex!(x::B, v, k) (Base.eachindex(x::B{T}) where {T})

julia> b = B([1,2,3])
B{Int64}([1, 2, 3])

julia> for i in eachindex(b)
         b[i] = b[i]^2
       end
julia> b[end]
9

julia> struct C
         d::Dict{String,Int}
       end
julia> @forward_methods C field=d Base.keytype(::Type{C}) Base.valtype(::Type{C})

julia> keytype(C)
String 

julia> valtype(C)
Int
```
"""
macro forward_methods(Type, field, args...)
    return forward_methods_expr(Type, field, args...; _sourceinfo=__source__) |> esc
end
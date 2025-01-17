object_argument(var, type) = Expr(:(::), var, type)
type_argument(type) = Expr(:(::), Expr(:curly, :Type, type))

function parse_kwarg_expr(expr; expr_name::String="", throw_error::Bool=true)
    @match expr begin 
        :($k = $v) => (k, v)
        _ => throw_error ? error("Expected a `key = value` expression" * (!isempty(expr_name) ? " from `$expr_name`" : "") * ", got `$expr") : nothing
    end
end

function is_unionall_type(ex::Expr)
    @switch ex begin 
        @case Expr(:curly, T, args...)
            return true
        @case _ 
            return false 
    end
end
is_unionall_type(ex) = false

function union_all_type_and_param(ex::Expr)
    @switch ex begin 
        @case Expr(:curly, T, args...)
            return T, args
        @case _ 
            error("Expression `$ex` is not of the form `A{T...}`")
    end
end
union_all_type_and_param(ex) = ex

function wrap_type_expr(T; additional_params=Symbol[])
    if is_unionall_type(T)
        _, params = union_all_type_and_param(T)
        all_params = [params..., additional_params...]
        return t->Expr(:where, t, all_params...)
    else
        return identity 
    end
end

function replace_placeholder(x::Symbol, replace_values::Vector{<:Pair{Symbol,<:Any}}) 
    for (old,new) in replace_values
        if x === old 
            return new, true
        end
    end
    return x, false
end
replace_placeholder(x, replace_values) = (x, false)

function replace_placeholder(x::Expr, replace_values::Vector{<:Pair{Symbol,<:Any}})
    replaced = false
    new_expr = Expr(x.head)
    for arg in x.args 
        new_arg, arg_replaced = replace_placeholder(arg, replace_values)
        push!(new_expr.args, new_arg)
        replaced |= arg_replaced
    end
    return new_expr, replaced
end

identity_map_expr(obj_expr, forwarded_expr) = forwarded_expr

function parse_map_func_expr(map_func_expr)
    if ((_, arg_replaced) = replace_placeholder(map_func_expr, [arg_placeholder => arg_placeholder]); arg_replaced)
        return let map_func_expr=map_func_expr
            (obj_expr, t::Expr) ->  replace_placeholder(map_func_expr, [obj_placeholder => obj_expr, arg_placeholder => t])[1]
        end
    else
        return nothing 
    end
end

function parse_map_expr(map_expr)
    kv = parse_kwarg_expr(map_expr; throw_error=false)
    isnothing(kv) && return nothing 
    key, value = kv 
    key != :map && return nothing
    return parse_map_func_expr(value)
end

function replace_first_arg_in_call_func(ex::Expr)
    @match ex begin 
        Expr(:call, func, arg1, args...) => let args=args; t->Expr(:call, func, t, args...) end
        Expr(:ref, arg1, args...) => let args=args; t->Expr(:ref, t, args...) end
        _ => error("Expression $ex must be a call expression")
    end
end

function parse_vect_of_symbols(expr; kwarg_name::Symbol)
    syms = from_expr(Vector{Symbol}, expr; throw_error=false)
    isnothing(syms) && error("`$kwarg_name` (= $expr) must be a Symbol or a `vect` expression of Symbols")
    return syms
end

function interface_kwarg!(kwargs::Dict{Symbol,Any}; allow_multiple::Bool=true)
    !haskey(kwargs, :interface) && error("Expected `interface` from keyword arguments")
    interface_val = pop!(kwargs, :interface)
    if allow_multiple
        return parse_vect_of_symbols(interface_val; kwarg_name=:interface)
    else
        interface_val isa Symbol || error("`interface` (= $interface_val) must be a `Symbol`, got typeof(interface) = $(typeof(interface_val))")
        return Symbol[interface_val]
    end
end

function omit_kwarg!(kwargs::Dict{Symbol,Any})
    omit_val = pop!(kwargs, :omit, nothing)
    if !isnothing(omit_val)
        return parse_vect_of_symbols(omit_val; kwarg_name=:omit)
    else
        return Symbol[]
    end
end

function get_kwarg(::Type{T}, kwargs, key::Symbol, default) where {T}
    value = get(kwargs, key, default)
    value isa T || error("$key (= $value) must be a $T, got typeof($key) = $(typeof(value))")
    return value
end

has_defined_interface(T, interface) = false

function wrap_define_interface(T, interface::Symbol, expr)
    return IfElseExpr(; if_else_exprs=[ 
        :(($ForwardMethods.has_defined_interface($T, Val($(QuoteNode(interface))))) == false) => Expr(:block, expr, :($ForwardMethods.has_defined_interface(::Type{$T}, ::Val{$(QuoteNode(interface))}) = true)) 
    ]) |> to_expr
end

const current_line_num = Base.RefValue{Union{Nothing, LineNumberNode}}(nothing)

function func_def_line_num!(expr, line::Union{NotProvided, LineNumberNode})
    f = from_expr(FuncDef, expr; throw_error=true)
    return FuncDef(f; line) |> to_expr
end
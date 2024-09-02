@testitem "Forward methods" setup=[SetupTest] begin 
    using ForwardMethods

    @forward_methods A field=v Base.length(x::A) Base.getindex(_, k) Base.eltype(::Type{A})

    test_func(v::Vector) = v[1]

    struct B{T}
        v::Vector{T}
    end
    @forward_methods B{T} field=getfield(b,:v) Base.length(x::B) (Base.getindex(_, k) where {T}) test_func

    struct C
        c::Vector{Int}
    end
    @forward_methods C field=c begin 
        Base.length
        Base.getindex(_, k)
    end

    @testset "@forward_methods" begin 
        @testset "Parsing" begin 
            @test_cases begin 
                input                        |  output_x                | output_y                  
                :(field=getproperty(_,:abc)) | :(Base.getproperty(x, :abc))  | :(Base.getproperty(y, :abc))
                :(field=Base.getproperty(_,:abc)) |  :(Base.getproperty(x, :abc))  | :(Base.getproperty(y, :abc)) 
                :(field=getindex(x,:k))      | :(Base.getindex(x,:k)) | :(Base.getindex(y, :k)) 
                :(field=t[])                 | :(x[])       | :(y[])
                :(field=t[1])                 | :(x[1])       | :(y[1])
                :(field=f(z))                | :(f(x)) | :(f(y)) 
                @test (ForwardMethods.parse_field(input).arg_func)(:x) == output_x
                @test (ForwardMethods.parse_field(input).arg_func)(:y) == output_y
                @test isnothing(ForwardMethods.parse_field(input).type_func)
            end
            @test_cases begin 
                input                        | output_arg_x             | output_arg_y               | output_type_x
                :(field=:abc)                | :(Base.getfield(x,:abc)) | :(Base.getfield(y,:abc))   | :(Base.fieldtype(x, :abc))
                :(field=abc)                 | :(Base.getfield(x,:abc)) | :(Base.getfield(y,:abc))   | :(Base.fieldtype(x, :abc))
                :(field=abc.def.ghi)         | :(Base.getfield(Base.getfield(Base.getfield(x,:abc), :def), :ghi)) | :(Base.getfield(Base.getfield(Base.getfield(y,:abc), :def), :ghi))   |  :(Base.fieldtype(Base.fieldtype(Base.fieldtype(x,:abc), :def), :ghi))
                :(field=getfield(_,:abc))    | :(Base.getfield(x,:abc)) | :(Base.getfield(y,:abc))   | :(Base.fieldtype(x, :abc))
                :(field=Base.getfield(_,:abc)) | :(Base.getfield(x,:abc)) | :(Base.getfield(y,:abc)) | :(Base.fieldtype(x, :abc))
                @test (ForwardMethods.parse_field(input).arg_func)(:x) == output_arg_x
                @test (ForwardMethods.parse_field(input).arg_func)(:y) == output_arg_y
                @test (ForwardMethods.parse_field(input).type_func)(:x) == output_type_x
            end
            @test_cases begin 
                Type        |  UnionallType  |   expr    |  output 
                :A          |  :A            | :(x::A)   | (; matches=true, unionall=false, type=false, arg=:x)
                :A          |  :A            | :(x::Type{A})   | (; matches=true, unionall=false, type=true, arg=:A)
                :(A{B,C})          |  :A            | :(x::Type{A})   | (; matches=true, unionall=true, type=true, arg=:A)
                :(A{B,C})          |  :A            | :(x::A{B,C})   | (; matches=true, unionall=false, type=false, arg=:x)
                :(A{B,C})          |  :A            | :(x::Type{A{B,C}})   | (; matches=true, unionall=false, type=true, arg=:(A{B,C}))
                @test ForwardMethods.matches_type_signature(Type, UnionallType, expr) == output
            end
            @test_cases begin 
                input        |  replace_values  |  output 
                (input=:_ , replace_values=[:_ => :t], output=(:t, true))
                (input=:(f(_)), replace_values=[:_ => :t], output=(:(f(t)), true))
                (input=:(f(x)), replace_values=[:_ => :t], output=(:(f(x)), false))
                (input=:(f(x)), replace_values=[:_ => :t, :x => :s], output=(:(f(s)), true))
                @test ForwardMethods.replace_placeholder(input, replace_values) == output
            end

            ref_obj = :x
            ref_expr = :(Base.iterate(Base.getfield(x,k)))
            @test_cases begin 
                input             |  output  
                :(map=_)          |  ref_expr 
                :(map=f(_))      |  :(f($ref_expr))
                :(map=begin z = f(_); g(z) end) | Expr(:block, :(z = f($ref_expr)), :(g(z)))
                :(map=begin z = f(_); g(z, _obj) end) | Expr(:block, :(z = f($ref_expr)), :(g(z, $ref_obj)))
                @test ForwardMethods.parse_map_expr(input)(ref_obj, ref_expr) == output
            end
            @Test isnothing(ForwardMethods.parse_map_expr(:x))
        end
        @testset "Expression generation" begin 
            field_funcs = ForwardMethods.FieldFuncExprs( (t)->:(Base.getproperty($t, :b)), nothing )
            matches_rhs = (t, x_ref=:x)->begin 
                @match t begin 
                    quote 
                        local $var1 = Base.getproperty($var2, :b)
                        Base.getindex($var3, k)
                    end => (var2 == x_ref && var1 == var3 )
                    _ => false
                end
            end
            for (T, input_expr) in ((:A, :(Base.getindex(x::A, k))), (:(A{B1,B2}), :(Base.getindex(x::A{B1,B2},k) where {B1,B2})), (:(A{B1,B2}), :(Base.getindex(x::A, k))))
                output = ForwardMethods.forward_method_signature(T, field_funcs, input_expr)
                matches = @switch output begin
                    @case :($lhs = $rhs) && if lhs == input_expr end 
                        matches_rhs(rhs)
                    @case _ 
                        false
                end
                @test matches
            end

            field_funcs = ForwardMethods.FieldFuncExprs( (t)->:(Base.getfield($t, :b)), (t) -> :(Base.fieldtype($t, :b)))
            T = :A 
            input_expr = :(Base.length) 
            matches_rhs = (t, x_ref=:x)->begin 
                @match t begin 
                    quote 
                        local $var1 = Base.getfield($var2, :b)
                        Base.length($var3)
                    end => (var2 == x_ref && var1 == var3 )
                    _ => false
                end
            end
            output = ForwardMethods.forward_method_signature(T, field_funcs, input_expr)
            matches = @switch output begin
                @case :($lhs = $rhs)
                    @match lhs begin 
                        :(Base.length($var1::A)) => matches_rhs(rhs, var1)
                        _ => false
                    end
                @case _ 
                    false
            end
            @test matches

            input_expr = :(Base.eltype(::Type{A})) 
            matches_rhs = (t, x_ref=:x)->begin 
                @match t begin 
                    quote 
                        local $var1 = Base.fieldtype($var2, :b)
                        Base.eltype($var3)
                    end => (var2 == x_ref && var1 == var3 )
                    _ => false
                end
            end
            output = ForwardMethods.forward_method_signature(T, field_funcs, input_expr)
            matches = @switch output begin
                @case :($lhs = $rhs)
                    @match lhs begin 
                        :(Base.eltype(::Type{A})) => matches_rhs(rhs, T)
                        _ => false
                    end
                @case _ 
                    false
            end
            @test matches
            
            # Testing underscore parameters 
            field_funcs = ForwardMethods.FieldFuncExprs( (t)->:(Base.getfield($t, :b)), (t) -> :(Base.fieldtype($t, :b)))
            T = :(A{B1,B2})  
            input_expr = :(Base.getindex(_, k) where {B1, B2})
            matches_rhs = (t, x_ref=:x)->begin 
                @match t begin 
                    quote 
                        local $var1 = Base.getfield($var2, :b)
                        Base.getindex($var3, k)
                    end => (var2 == x_ref && var1 == var3 )
                    _ => false
                end
            end
            output = ForwardMethods.forward_method_signature(T, field_funcs, input_expr)
            matches = @switch output begin
                @case :($lhs = $rhs)
                    @match lhs begin 
                        :(Base.getindex($var1::A{B1,B2}, k) where {B1,B2}) => matches_rhs(rhs, var1)
                        _ => false
                    end
                @case _ 
                    false
            end
            @test matches

            
            # If provided type is parametric but signature does not qualify where statement -- use unionall type in signature
            T = :(C.A{B1,B2})  
            input_expr = :(Base.getindex(_, k))
            output = ForwardMethods.forward_method_signature(T, field_funcs, input_expr)
            matches = @switch output begin
                @case :($lhs = $rhs)
                    @match lhs begin 
                        :(Base.getindex($var1::C.A, k)) => matches_rhs(rhs, var1)
                        _ => false
                    end
                @case _ 
                    false
            end
            @test matches
        end
        @testset "Forwarded methods" begin 
            @Test custom_func_to_forward(A([0])) == 0
            @Test length(A([0])) == 1
            @Test A([0])[1] == 0
            @Test eltype(A) == Int

            @Test length(B([0])) == 1
            @Test B([0])[1] == 0
            c = C([1])
            @Test length(c) == 1
            @test_opt length(c) 
        end
    end
end
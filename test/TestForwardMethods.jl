module TestForwardMethods 
    using ForwardMethods, ForwardMethods.MLStyle 

    using Test, TestingUtilities 

    struct A
        v::Vector{Int}
    end
    @forward_methods A field=v Base.length(x::A) Base.getindex(_, k) Base.eltype(::Type{A})

    test_func(v::Vector) = v[1]

    struct B{T}
        v::Vector{T}
    end
    @forward_methods B{T} field=getfield(b,:v) Base.length(x::B) (Base.getindex(_, k) where {T}) test_func

    struct ForwardDict
        d::Dict{String,Int}
    end
    @forward_interface ForwardDict field=d interface=dict

    struct ForwardVector{T}
        v::Vector{T}
    end
    @forward_interface ForwardVector{T} field=v interface=array index_style_linear=true 

    struct ForwardVectorNoLength{T}
        v::Vector{T}
    end
    @forward_interface ForwardVectorNoLength{T} field=v interface=array index_style_linear=true omit=[length]

    struct ForwardMatrix{F}
        v::Matrix{F}
    end
    @forward_interface ForwardMatrix{F} field=v interface=array index_style_linear=false 

    struct LockableDict{K,V}
        d::Dict{K,V}
        lock::ReentrantLock
    end
    @forward_interface LockableDict{K,V} field=lock interface=lockable
    @forward_interface LockableDict{K,V} field=d interface=dict map=begin lock(_obj); try _ finally unlock(_obj) end end

    @testset "@forward" begin 
        @testset "Parsing" begin 
            @test_cases begin 
                input                        |  output_x                | output_y                  | output_arg2
                :(field=:abc)                | :(Base.getfield(x,:abc)) | :(Base.getfield(y,:abc))  | :abc
                :(field=abc)                 | :(Base.getfield(x,:abc)) | :(Base.getfield(y,:abc))  | :abc
                :(field=getproperty(_,:abc)) | :(Base.getproperty(x, :abc))  | :(Base.getproperty(y, :abc)) | nothing
                :(field=Base.getproperty(_,:abc)) |  :(Base.getproperty(x, :abc))  | :(Base.getproperty(y, :abc)) | nothing
                :(field=getfield(_,:abc))    | :(Base.getfield(x,:abc)) | :(Base.getfield(y,:abc)) | :abc
                :(field=Base.getfield(_,:abc)) | :(Base.getfield(x,:abc)) | :(Base.getfield(y,:abc)) | :abc
                :(field=getindex(x,:k))      | :(Base.getindex(x,:k)) | :(Base.getindex(y, :k)) | nothing
                :(field=t[])                 | :(x[])       | :(y[]) | nothing
                :(field=t[1])                 | :(x[1])       | :(y[1]) | nothing
                :(field=f(z))                | :(f(x)) | :(f(y)) | nothing
                @test (ForwardMethods.parse_field(input)[1])(:x) == output_x
                @test isequal(ForwardMethods.parse_field(input)[2], output_arg2)
                @test (ForwardMethods.parse_field(input)[1])(:y) == output_y
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
            field_func = (t)->:(Base.getproperty($t, :b))
            field_name = nothing
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
                output = ForwardMethods.forward_method_signature(T, field_func, field_name, input_expr)
                matches = @switch output begin
                    @case :($lhs = $rhs) && if lhs == input_expr end 
                        matches_rhs(rhs)
                    @case _ 
                        false
                end
                @test matches
            end

            field_func = (t)->:(Base.getfield($t, :b))
            field_name = :b
            T = :A 
            new_input_expr = :(Base.length) 
            matches_rhs = (t, x_ref=:x)->begin 
                @match t begin 
                    quote 
                        local $var1 = Base.getfield($var2, :b)
                        Base.length($var3)
                    end => (var2 == x_ref && var1 == var3 )
                    _ => false
                end
            end
            output = ForwardMethods.forward_method_signature(T, field_func, field_name, new_input_expr)
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

            new_input_expr = :(Base.eltype(::Type{A})) 
            matches_rhs = (t, x_ref=:x)->begin 
                @match t begin 
                    quote 
                        local $var1 = Base.fieldtype($var2, :b)
                        Base.eltype($var3)
                    end => (var2 == x_ref && var1 == var3 )
                    _ => false
                end
            end
            output = ForwardMethods.forward_method_signature(T, field_func, field_name, new_input_expr)
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
            field_func = (t)->:(Base.getfield($t, :b))
            field_name = :b
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
            output = ForwardMethods.forward_method_signature(T, field_func, field_name, input_expr)
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
            output = ForwardMethods.forward_method_signature(T, field_func, field_name, input_expr)
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

        @Test length(A([0])) == 1
        @Test A([0])[1] == 0
        @Test eltype(A) == Int

        @Test length(B([0])) == 1
        @Test B([0])[1] == 0
    end

    @testset "@forward_interface" begin 
        d = ForwardDict(Dict{String, Int}())
        @Test isempty(d)
        @Test !haskey(d, "a")
        @Test isnothing(pop!(d, "a", nothing))
        @Test isnothing(get(d, "a", nothing))
        d["a"] = 1
        d["b"] = 2
        @Test !isempty(d)
        @Test haskey(d, "a")
        @Test d["a"] == 1
        @Test keytype(typeof(d)) == String
        @Test valtype(typeof(d)) == Int
        @Test eltype(typeof(d)) == Pair{String, Int}
        @Test ("a" => 1) in d
        @Test "a" ∈ keys(d)
        @Test Set(collect(pairs(d))) == Set(["a" => 1, "b" => 2])
        @Test 1 ∈ values(d)
        empty!(d)
        @Test isempty(d)
        
        f = ForwardVector(Int[])
        @Test isempty(f)
        @Test size(f) == (0,)
        @Test length(f) == 0
        f = ForwardVector([1,3,3])
        @Test f[2] == 3
        f[2] = 2
        @Test f[2] == 2
        @Test length(f) == 3
        for (i, fi) in enumerate(f)
            @Test i == fi 
        end 

        m = ForwardMatrix([1.0 0.0; 0.0 1.0])
        @Test size(m) == (2,2)
        @Test m[1,1] == 1.0
        m[1,1] = 2.0
        @Test m[1,1] == 2.0
        
        f = ForwardVectorNoLength([1,3,3])
        @test_throws MethodError length(f)
        @Test f[2] == 3
        f[2] = 2
        @Test f[2] == 2
        for (i, fi) in enumerate(f)
            @Test i == fi 
        end 

        l = LockableDict(Dict{String,Int}(), ReentrantLock())
        l["a"] = 1
        @Test l["a"] == 1
    end
end
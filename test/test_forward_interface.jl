@testitem "Forward Interfaces" setup=[SetupTest] begin 

    function custom_interface(T; omit::AbstractVector{Symbol}=Symbol[])
        return [:custom_func_to_forward]
    end

    @Test !(:custom in ForwardMethods.forward_interfaces_available())

    ForwardMethods.forward_interface_method(::Val{:custom}) = custom_interface

    @Test :custom in ForwardMethods.forward_interfaces_available()

    @forward_interface A field=v interface=custom

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

    struct ForwardVectorInterface{T}
        v::Vector{T}
    end
    @forward_interface ForwardVectorInterface{T} field=v interface=vector

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

    struct InnerVector 
        v::Vector{Int}
    end
    struct NestedForward
        h::InnerVector
    end
    @forward_interface NestedForward field=h.v interface=array index_style_linear=true


    @testset "@forward_interface" begin 
        v = NestedForward(InnerVector([1,2,3]))
        @Test v[1] == 1

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
        @test_throws_compat MethodError "MethodError: no method matching lastindex(::$ForwardVector{Int64})" f[end]
        @Test f[1:3] == [1,3,3]
        @Test f[2] == 3
        f[2] = 2
        @Test f[2] == 2
        @Test length(f) == 3
        for (i, fi) in enumerate(f)
            @Test i == fi 
        end 
        @Test eltype(f) == Any

        f = ForwardVectorInterface(Int[])
        @Test isempty(f)
        @Test size(f) == (0,)
        @Test length(f) == 0
        @Test eltype(f) == Int
        @Test eltype(ForwardVectorInterface{Int}) == Int
        f = ForwardVectorInterface([1,3,3])
        @Test f[begin] == 1
        @Test f[end] == 3
        @Test f[begin:end] == [1,3,3]
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
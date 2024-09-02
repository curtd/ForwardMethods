using TestItemRunner, TestItems

@testsnippet SetupTest begin 
    using ForwardMethods.MLStyle 

    using JET, Test, TestingUtilities 

    macro test_throws_compat(ExceptionType, message, expr)
        output = Expr(:block, __source__, :($Test.@test_throws $ExceptionType $expr))
        if VERSION ≥ v"1.7"
            push!(output.args, :($Test.@test_throws $message $expr))
        end
        return output |> esc
    end

    struct A
        v::Vector{Int}
    end
    mutable struct SettableProperties 
        key1::String 
        key2::Int 
        key3::Bool
    end
    mutable struct SettableProperties2
        key4::Float64
        key5::Vector{Int}
    end
    custom_func_to_forward(t) = t[1]
end
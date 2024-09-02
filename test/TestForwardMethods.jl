module TestForwardMethods 
    using ForwardMethods

    include("test_forward_methods.jl")
    include("test_forward_interface.jl")
    include("define_interface/_test_define_interface.jl")
end
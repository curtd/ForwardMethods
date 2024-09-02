@testitem "@define_interface" setup=[SetupTest] begin 
    include("test_properties.jl")
    include("test_equality.jl")
    include("test_getfields_setfields.jl")
end
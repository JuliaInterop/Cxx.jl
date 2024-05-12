abstract type AbstractJLLEnv end

struct MacEnv <: AbstractJLLEnv
    platform::Platform
    gcc_version::VersionNumber
    is_cxx::Bool
end

struct GnuEnv <: AbstractJLLEnv
    platform::Platform
    gcc_version::VersionNumber
    is_cxx::Bool
end

struct MuslEnv <: AbstractJLLEnv
    platform::Platform
    gcc_version::VersionNumber
    is_cxx::Bool
end

struct WindowsEnv <: AbstractJLLEnv
    platform::Platform
    gcc_version::VersionNumber
    is_cxx::Bool
end

struct ArmEnv <: AbstractJLLEnv
    platform::Platform
    gcc_version::VersionNumber
    is_cxx::Bool
end

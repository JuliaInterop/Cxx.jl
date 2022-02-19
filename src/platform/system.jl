function get_default_env(; version::VersionNumber=GCC_MIN_VER, is_cxx=false)
    p = HostPlatform()
    if os(p) == "macos"
        return MacEnv(p, version, is_cxx)
    elseif os(p) == "windows"
        return WindowsEnv(p, version, is_cxx)
    elseif arch(p) == "armv7l"
        return ArmEnv(p, version, is_cxx)
    elseif libc(p) == "musl"
        return MuslEnv(p, version, is_cxx)
    elseif libc(p) == "glibc" || libc(p) == "gnu"
        return GnuEnv(p, version, is_cxx)
    else
        @warn "unknown platform! using default GNU environment."
        return GnuEnv(p, version, is_cxx)
    end
end

function get_system_includes(env::AbstractJLLEnv=get_default_env())
    info = get_environment_info(env.platform, env.gcc_version)
    gcc_info = info[1]
    sys_info = info[2]

    # download shards
    download_artifact(Base.SHA1(gcc_info.id), gcc_info.url, gcc_info.chk)
    # download_artifact(Base.SHA1(sys_info.id), sys_info.url, sys_info.chk)

    # -isystem paths
    gcc_prefix = artifact_path(Base.SHA1(gcc_info.id))
    # sys_prefix = artifact_path(Base.SHA1(sys_info.id))

    isys = String[]
    get_system_includes!(env, gcc_prefix, isys)

    for dir in isys
        @assert isdir(dir) "failed to setup environment due to missing dir: $dir, please file an issue."
    end

    return normpath.(isys)
end

function get_system_includes!(env::MacEnv, prefix::String, isys::Vector{String})
    p = env.platform
    triple = __triplet(env.platform)
    version = env.gcc_version
    if os(p) == "macos" && arch(p) == "x86_64"
        if env.is_cxx
            push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include", "c++", "v1"))
            push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include"))
            push!(isys, joinpath(prefix, triple, "include", "c++", string(version)))
            push!(isys, joinpath(prefix, triple, "include", "c++", string(version), triple))
            push!(isys,
                  joinpath(prefix, triple, "include", "c++", string(version), "backward"))
            push!(isys, joinpath(prefix, triple, "include"))
            push!(isys,
                  joinpath(prefix, triple, "sys-root", "System", "Library", "Frameworks"))
        else
            push!(isys, joinpath(prefix, "lib", "gcc", triple, string(version), "include"))
            push!(isys,
                  joinpath(prefix, "lib", "gcc", triple, string(version), "include-fixed"))
            push!(isys, joinpath(prefix, triple, "include"))
            push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include"))
            push!(isys,
                  joinpath(prefix, triple, "sys-root", "System", "Library", "Frameworks"))
        end
    else  # "aarch64-apple-darwin20"
        if env.is_cxx
            push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include", "c++", "v1"))
            push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include"))
            push!(isys, joinpath(prefix, triple, "include", "c++", "11.0.0"))
            push!(isys, joinpath(prefix, triple, "include", "c++", "11.0.0", triple))
            push!(isys, joinpath(prefix, triple, "include", "c++", "11.0.0", "backward"))
        else
            push!(isys, joinpath(prefix, "lib", "gcc", triple, "11.0.0", "include"))
            push!(isys, joinpath(prefix, "lib", "gcc", triple, "11.0.0", "include-fixed"))
            push!(isys, joinpath(prefix, triple, "include"))
            push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include"))
            push!(isys,
                  joinpath(prefix, triple, "sys-root", "System", "Library", "Frameworks"))
        end
    end
end

function get_system_includes!(env::WindowsEnv, prefix::String, isys::Vector{String})
    triple = __triplet(env.platform)
    version = env.gcc_version
    if env.is_cxx
        push!(isys, joinpath(prefix, triple, "include", "c++", string(version)))
        push!(isys, joinpath(prefix, triple, "include", "c++", string(version), triple))
        push!(isys, joinpath(prefix, triple, "include", "c++", string(version), "backward"))
        push!(isys, joinpath(prefix, triple, "include"))
        push!(isys, joinpath(prefix, triple, "sys-root", "include"))
    else
        push!(isys, joinpath(prefix, "lib", "gcc", triple, string(version), "include"))
        push!(isys,
              joinpath(prefix, "lib", "gcc", triple, string(version), "include-fixed"))
        push!(isys, joinpath(prefix, triple, "include"))
        push!(isys, joinpath(prefix, triple, "sys-root", "include"))
    end
end

function get_system_includes!(env::GnuEnv, prefix::String, isys::Vector{String})
    triple = __triplet(env.platform)
    version = env.gcc_version
    if env.is_cxx
        push!(isys, joinpath(prefix, triple, "include", "c++", string(version)))
        push!(isys, joinpath(prefix, triple, "include", "c++", string(version), triple))
        push!(isys, joinpath(prefix, triple, "include", "c++", string(version), "backward"))
        push!(isys, joinpath(prefix, triple, "include"))
        push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include"))
    else
        push!(isys, joinpath(prefix, "lib", "gcc", triple, string(version), "include"))
        push!(isys,
              joinpath(prefix, "lib", "gcc", triple, string(version), "include-fixed"))
        push!(isys, joinpath(prefix, triple, "include"))
        push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include"))
    end
end

function get_system_includes!(env::MuslEnv, prefix::String, isys::Vector{String})
    triple = __triplet(env.platform)
    version = env.gcc_version
    if env.is_cxx
        push!(isys, joinpath(prefix, triple, "include", "c++", string(version)))
        push!(isys, joinpath(prefix, triple, "include", "c++", string(version), triple))
        push!(isys, joinpath(prefix, triple, "include", "c++", string(version), "backward"))
        push!(isys, joinpath(prefix, triple, "include"))
        push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include"))
    else
        push!(isys, joinpath(prefix, "lib", "gcc", triple, string(version), "include"))
        push!(isys, joinpath(prefix, triple, "include"))
        push!(isys, joinpath(prefix, triple, "sys-root", "usr", "include"))
    end
end

function get_system_includes!(env::ArmEnv, prefix::String, isys::Vector{String})
    triple = __triplet(env.platform)
    version = env.gcc_version
    if env.platform == Platform("armv7l", "linux")
        if env.is_cxx
            push!(isys,
                  joinpath(prefix, "arm-linux-gnueabihf", "include", "c++",
                           string(version)))
            push!(isys,
                  joinpath(prefix, "arm-linux-gnueabihf", "include", "c++", string(version),
                           "arm-linux-gnueabihf"))
            push!(isys,
                  joinpath(prefix, "arm-linux-gnueabihf", "include", "c++", string(version),
                           "backward"))
            push!(isys, joinpath(prefix, "arm-linux-gnueabihf", "include"))
            push!(isys,
                  joinpath(prefix, "arm-linux-gnueabihf", "sys-root", "usr", "include"))
        else
            push!(isys,
                  joinpath(prefix, "lib", "gcc", "arm-linux-gnueabihf", string(version),
                           "include"))
            push!(isys,
                  joinpath(prefix, "lib", "gcc", "arm-linux-gnueabihf", string(version),
                           "include-fixed"))
            push!(isys, joinpath(prefix, "arm-linux-gnueabihf", "include"))
            push!(isys,
                  joinpath(prefix, "arm-linux-gnueabihf", "sys-root", "usr", "include"))
        end
    else  # "armv7l-linux-musleabihf"
        if env.is_cxx
            push!(isys,
                  joinpath(prefix, "arm-linux-musleabihf", "include", "c++",
                           string(version)))
            push!(isys,
                  joinpath(prefix, "arm-linux-musleabihf", "include", "c++",
                           string(version), "arm-linux-musleabihf"))
            push!(isys,
                  joinpath(prefix, "arm-linux-musleabihf", "include", "c++",
                           string(version), "backward"))
            push!(isys, joinpath(prefix, "arm-linux-musleabihf", "include"))
            push!(isys,
                  joinpath(prefix, "arm-linux-musleabihf", "sys-root", "usr", "include"))
        else
            push!(isys,
                  joinpath(prefix, "lib", "gcc", "arm-linux-musleabihf", string(version),
                           "include"))
            push!(isys,
                  joinpath(prefix, "lib", "gcc", "arm-linux-musleabihf", string(version),
                           "include-fixed"))
            push!(isys, joinpath(prefix, "arm-linux-musleabihf", "include"))
            push!(isys,
                  joinpath(prefix, "arm-linux-musleabihf", "sys-root", "usr", "include"))
        end
    end
end

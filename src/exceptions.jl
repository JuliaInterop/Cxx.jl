const libcxx_class               = 0x434C4E47432B2B00
const libcxx_dependent_class     = 0x434C4E47432B2B01
const get_vendor_and_language    = 0xFFFFFFFFFFFFFF00

const libstdcxx_class =
  bswap(reinterpret(UInt64,UInt8['G','N','U','C','C','+','+','\0'])[1])
const libstdcxx_depdendent_class =
  bswap(reinterpret(UInt64,UInt8['G','N','U','C','C','+','+','\x1'])[1])

immutable _UnwindException
    class::UInt64
    cleanup::Ptr{Void}
    private1::UInt
    private2::UInt
end

immutable LibCxxException
    referenceCount::Csize_t
    exceptionType::pcpp"std::type_info"
    exceptionDestructor::Ptr{Void}
    unexpectedHandler::Ptr{Void}
    terminate_handler::Ptr{Void}
    nextException::Ptr{Void}
    handlerCount::Cint
    handlerSwitchValue::Cint
    actionRecord::Ptr{UInt8}
    lsa::Ptr{UInt8}
    catchTemp::Ptr{Void}
    adjustedPtr::Ptr{Void}
    unwindHeader::_UnwindException
end

const LibStdCxxException = LibCxxException

immutable CxxException{kind}
    exception::Ptr{LibCxxException}
end

function exceptionObject(e::CxxException,T)
    unsafe_load(convert(Ptr{T},(e.exception+sizeof(LibCxxException))))
end

function exceptionObject{T<:CppRef}(e::CxxException,::Type{T})
    T(convert(Ptr{Void},(e.exception+sizeof(LibCxxException))))
end

function show_cxx_backtrace(io::IO, t, set=1:typemax(Int))
    show_cxx_backtrace(io,Base.eval_user_input.env.name,t, set)
end

function show_cxx_backtrace(io::IO, top_function::Symbol, t, set)
    local process_entry
    let saw_unwind_resume = false
        function process_entry(lastname, lastfile, lastline, last_inlinedat_file, last_inlinedat_line, n)
            if lastname == :_Unwind_Resume
                saw_unwind_resume = true
                return
            end
            saw_unwind_resume || return
            lastname == Symbol("???") && return
            Base.show_trace_entry(io, lastname, lastfile, lastline, last_inlinedat_file, last_inlinedat_line, n)
        end
    end
    Base.process_backtrace(process_entry, top_function, t, set; skipC = false)
end

import Base: showerror
function showerror{kind}(io::IO, e::CxxException{kind})
    print(io,"Unrecognized C++ Exception ($kind)")
end
function showerror{kind}(io::IO, e::CxxException{kind}, bt)
    showerror(io, e)
    show_cxx_backtrace(io, bt)
end

function process_cxx_exception(code::UInt64, e::Ptr{Void})
    e = Ptr{_UnwindException}(e)
    if (code & get_vendor_and_language) == libcxx_class
        # This is a libc++ exception
        offset = Base.fieldoffset(LibCxxException,length(LibCxxException.types))
        cxxe = Ptr{LibCxxException}(e - offset)
        T = unsafe_load(cxxe).exceptionType
        throw(CxxException{Symbol(bytestring(icxx"$T->name();"))}(cxxe))
    elseif (code & get_vendor_and_language) == libstdcxx_class
        # This is a libstdc++ exception
        offset = Base.fieldoffset(LibStdCxxException,length(LibStdCxxException.types))
        cxxe = Ptr{LibStdCxxException}(e - offset)
        T = unsafe_load(cxxe).exceptionType
        throw(CxxException{Symbol(unsafe_string(icxx"$T->name();"))}(cxxe))
    end
    error("Caught a C++ exception")
end

# Get the typename, but strip refence
@generated function typename(CT, Ty)
    if Ty <: Type || Ty <: Val
        Ty = Ty.parameters[1]
    end
    C = instance(CT)
    T = cpptype(C, Ty)
    if isReferenceType(T)
        T = getPointeeType(T)
    end
    s = Symbol(getTypeName(C, T))
    quot(s)
end

# Rewrite a `showerror` definition to dispatch on the exception wrapper instead
macro exception(e)
    if isexpr(e,:function)
        (e.args[1].args[1] == :showerror) || error("@exception can only be used with `showerror` not `$(e.args[1].args[1]). See usage.")
        callargs = e.args[1].args[2:end]
        length(callargs) == 2 || error("Only the two argument version of `showerror` is supported")
        exarg = callargs[2]
        argsym = exarg.args[1]
        argtype = exarg.args[2]
        isexpr(exarg,:(::)) || error("The exception argument needs a type annotation")
        e.args[1].args[3] = :( $argsym::Cxx.CxxException{Cxx.typename(__current_compiler__,Val{$argtype}())} )
        unshift!(e.args[2].args, :( $argsym = Cxx.exceptionObject($argsym,$argtype) ))
        return esc(e)
    end
    error("@exception used on something other than a function")
end

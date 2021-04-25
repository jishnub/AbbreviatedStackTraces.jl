module AbbreviatedStackTraces
__precompile__(false)

import REPL:
    print_response

import Base:
    BIG_STACKTRACE_SIZE,
    catch_stack,
    invokelatest,
    printstyled,
    scrub_repl_backtrace,
    show,
    showerror,
    show_backtrace,
    show_exception_stack,
    show_full_backtrace,
    StackFrame,
    STACKTRACE_FIXEDCOLORS,
    STACKTRACE_MODULECOLORS,
    stacktrace_linebreaks,
    print_stackframe,
    process_backtrace,
    update_stackframes_callback

import Base.StackTraces:
    is_top_level_frame

is_base_not_REPL(path) = startswith(path, r".[/\\]") && !startswith(path, r".[/\\]REPL")
is_registry_pkg(path) = contains(path, r"[/\\].julia[/\\]packages[/\\]")
is_dev_pkg(path) = contains(path, r"[/\\].julia[/\\]dev[/\\]")
is_stdlib(path) = contains(path, r"[/\\]julia[/\\]stdlib")
is_private_not_julia(path) = contains(path, r"[/\\].*[/\\]") && !contains(path, r"[/\\].julia[/\\]")

function show_compact_backtrace(io::IO, trace::Vector; print_linebreaks::Bool)
    #= Show the lowest stackframe and display a message telling user how to
    retrieve the full trace =#

    num_frames = length(trace)
    ndigits_max = ndigits(num_frames)

    modulecolordict = copy(STACKTRACE_FIXEDCOLORS)
    modulecolorcycler = Iterators.Stateful(Iterators.cycle(STACKTRACE_MODULECOLORS))

    function print_omitted_modules(i, j)
        # Find modules involved in intermediate frames and print them
        modules = filter(!isnothing, unique(t[1] |> parentmodule for t ∈ @view trace[i:j]))
        length(modules) > 0 || return
        print(io, " " ^ (ndigits_max + 2))
        for m ∈ modules
            modulecolor = get_modulecolor!(modulecolordict, m, modulecolorcycler)
            printstyled(io, m, color = modulecolor)
            print(io, " ")
        end
        println(io)
    end

    # select frames from user-controlled code
    is = findall(trace) do frame
        file = String(frame[1].file)
        !is_base_not_REPL(file) &&
        !is_registry_pkg(file) &&
        !is_stdlib(file) &&
        !is_private_not_julia(file) ||
        is_dev_pkg(file) ||
        is_top_level_frame(frame[1])
    end

    # get list of visible modules
    visible_modules = convert(Vector{Module}, filter!(!isnothing, unique(t[1] |> parentmodule for t ∈ @view trace[is])))
    Main ∈ visible_modules || push!(visible_modules, Main)

    # find the highest contiguous internal frames evaluted in the context of a visible module
    internali = setdiff!(findall(trace) do frame
        parentmodule(frame[1]) ∈ visible_modules
    end, is)
    setdiff!(internali, internali .+ 1)

    # include the immediate frame called into from user-controlled code
    filter!(>(0), sort!(union!(is, is .- 1, internali .- 1)))

    if length(is) > 0
        println(io, "\nStacktrace:")

        if is[1] > 1
            print_omitted_modules(1, is[1])
            println(io, repeat(' ', ndigits_max + 2) * "⋮")
        end

        lasti = first(is)
        @views for i ∈ is
            if i > lasti + 1
                println(io, repeat(' ', ndigits_max + 2) * "⋮")
                print_omitted_modules(lasti + 1, i - 1)
                println(io, repeat(' ', ndigits_max + 2) * "⋮")
            end
            print_stackframe(io, i, trace[i][1], trace[i][2], ndigits_max, modulecolordict, modulecolorcycler)
            if i < num_frames
                println(io)
                print_linebreaks && println(io)
            end
            lasti = i
        end
    end

    length(trace) > length(is) && print(io, "\nUse `err` to retrieve the full stack trace.")
end

function get_modulecolor!(modulecolordict, m, modulecolorcycler)
    if m !== nothing
        while parentmodule(m) !== m
            pm = parentmodule(m)
            pm == Main && break
            m = pm
        end
        if !haskey(modulecolordict, m)
            modulecolordict[m] = popfirst!(modulecolorcycler)
        end
        return modulecolordict[m]
    else
        return :default
    end
end

# copied from client.jl with added compacttrace argument
function display_error(io::IO, er, bt, compacttrace = false)
    printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
    bt = scrub_repl_backtrace(bt)
    showerror(IOContext(io, :limit => true, :compacttrace => compacttrace), er, bt; backtrace = bt!==nothing)
    println(io)
end
function display_error(io::IO, stack::Vector, compacttrace = false)
    printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
    bt = Any[ (x[1], scrub_repl_backtrace(x[2])) for x in stack ]
    show_exception_stack(IOContext(io, :limit => true, :compacttrace => compacttrace), bt)
    println(io)
end

# copied from errorshow.jl with added compacttrace argument
function show_exception_stack(io::IO, stack::Vector)
    # Display exception stack with the top of the stack first.  This ordering
    # means that the user doesn't have to scroll up in the REPL to discover the
    # root cause.
    nexc = length(stack)
    for i = nexc:-1:1
        if nexc != i
            printstyled(io, "\ncaused by: ", color=Base.error_color())
        end
        exc, bt = stack[i]
        showerror(io, exc, bt; backtrace = bt!==nothing)
        i == 1 || println(io)
    end
end
function show_backtrace(io::IO, t::Vector)
    if haskey(io, :last_shown_line_infos)
        empty!(io[:last_shown_line_infos])
    end

    # t is a pre-processed backtrace (ref #12856)
    if t isa Vector{Any}
        filtered = t
    else
        filtered = process_backtrace(t)
    end
    isempty(filtered) && return

    if length(filtered) == 1 && StackTraces.is_top_level_frame(filtered[1][1])
        f = filtered[1][1]::StackFrame
        if f.line == 0 && f.file === Symbol("")
            # don't show a single top-level frame with no location info
            return
        end
    end

    if length(filtered) > BIG_STACKTRACE_SIZE
        show_reduced_backtrace(IOContext(io, :backtrace => true), filtered)
        return
    end

    try invokelatest(update_stackframes_callback[], filtered) catch end
    # process_backtrace returns a Vector{Tuple{Frame, Int}}
    if get(io, :compacttrace, false)
        show_compact_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
    else
        show_full_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
    end
    return
end

struct ExceptionInfo
    errors::Vector{Tuple{Any, Vector{Union{Ptr{Nothing}, Base.InterpreterIP}}}}
end

show(io::IO, exs::ExceptionInfo) = display_error(io, exs.errors)

# copied from REPL.jl with addition of :err global
function print_response(errio::IO, response, show_value::Bool, have_color::Bool, specialdisplay::Union{AbstractDisplay,Nothing}=nothing)
    Base.sigatomic_begin()
    val, iserr = response
    while true
        try
            Base.sigatomic_end()
            if iserr
                ccall(:jl_set_global, Cvoid, (Any, Any, Any), Main, :err, ExceptionInfo(val))
                Base.invokelatest(display_error, errio, val, true)
            else
                if val !== nothing && show_value
                    try
                        if specialdisplay === nothing
                            Base.invokelatest(display, val)
                        else
                            Base.invokelatest(display, specialdisplay, val)
                        end
                    catch
                        println(errio, "Error showing value of type ", typeof(val), ":")
                        rethrow()
                    end
                end
            end
            break
        catch
            if iserr
                println(errio) # an error during printing is likely to leave us mid-line
                println(errio, "SYSTEM (REPL): showing an error caused an error")
                try
                    Base.invokelatest(Base.display_error, errio, catch_stack())
                catch e
                    # at this point, only print the name of the type as a Symbol to
                    # minimize the possibility of further errors.
                    println(errio)
                    println(errio, "SYSTEM (REPL): caught exception of type ", typeof(e).name.name,
                            " while trying to handle a nested exception; giving up")
                end
                break
            end
            val = catch_stack()
            iserr = true
        end
    end
    Base.sigatomic_end()
    nothing
end

end
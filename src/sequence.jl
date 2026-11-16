"""
    variable = StudioVariable(name, script; readonly=false)

A named [`StudioScript`](@ref). Variables are evaluated in definition order by the
whitelist interpreter. `return` sets its value, and a script without `return`
uses its last expression. Earlier variables, `pi`, and `γ` are available by
name. Loop iterators are not. `pi` is reserved. `readonly` is UI metadata.
`script` may be the source text or a `StudioScript`.
"""
struct StudioVariable
    name::Symbol
    script::StudioScript
    readonly::Bool
    function StudioVariable(name, script; readonly::Bool=false)
        symbol = name isa Symbol ? name : Symbol(name)
        occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", String(symbol)) ||
            error("Invalid variable name: $name")
        symbol == :pi && error("pi is reserved")
        text = script isa StudioScript ? script.source : String(strip(script))
        isempty(text) && error("Script of $symbol is empty")
        code = try
            _code(script)
        catch err
            error("Script of $symbol is not allowed. $(sprint(showerror, err))")
        end
        new(symbol, code, readonly)
    end
end

"""
    gr = StudioGrad(A, T)
    gr = StudioGrad(A, T, rise)
    gr = StudioGrad(A, T, rise, delay)
    gr = StudioGrad(A, T, rise, fall, delay)

Trapezoidal gradient in Koma units (`A` in T/m, times in s). Fields hold
scripts in the same whitelist as variables, and can see the loop iterator.
`StudioGrad()` is off: amplitude and timings are `0`. The four-argument
form sets `fall = rise`, as Koma's `Grad` does.
"""
struct StudioGrad
    A::StudioScript
    T::StudioScript
    rise::StudioScript
    fall::StudioScript
    delay::StudioScript
    function StudioGrad(A, T, rise, fall, delay)
        new(_code(A), _code(T), _code(rise), _code(fall), _code(delay))
    end
end

StudioGrad(A, T, rise, delay) = StudioGrad(A, T, rise, rise, delay)
StudioGrad(A, T, rise) = StudioGrad(A, T, rise, rise, "0")
StudioGrad(A, T) = StudioGrad(A, T, "0", "0", "0")
StudioGrad() = StudioGrad("0", "0")

"""
    rf = StudioRF(A, T)
    rf = StudioRF(A, T, Δf, delay, ϕ, use)

Block RF pulse in Koma units (`A` in T, `T` and `delay` in s, `Δf` in Hz, `ϕ` in rad).
`use` is a Koma RF use, such as `Excitation()` or `Undefined()`. `StudioRF()` is off.
"""
struct StudioRF{U<:RFUse}
    A::StudioScript
    T::StudioScript
    Δf::StudioScript
    delay::StudioScript
    ϕ::StudioScript
    use::U
    function StudioRF(A, T, Δf, delay, ϕ, use::RFUse)
        new{typeof(use)}(_code(A), _code(T), _code(Δf), _code(delay), _code(ϕ), use)
    end
end

StudioRF(A, T, Δf, delay, ϕ) = StudioRF(A, T, Δf, delay, ϕ, Undefined())
StudioRF(A, T, Δf, delay) = StudioRF(A, T, Δf, delay, "0")
StudioRF(A, T, Δf) = StudioRF(A, T, Δf, "0")
StudioRF(A, T) = StudioRF(A, T, "0")
StudioRF() = StudioRF("0", "0")

"""
    adc = StudioADC(N, T)
    adc = StudioADC(N, T, delay, Δf, ϕ)

Acquisition window in Koma units (`N` samples, `T` and `delay` in s, `Δf` in Hz,
`ϕ` in rad). `StudioADC()` acquires nothing (`N = 0`).
"""
struct StudioADC
    N::StudioScript
    T::StudioScript
    delay::StudioScript
    Δf::StudioScript
    ϕ::StudioScript
    function StudioADC(N, T, delay, Δf, ϕ)
        new(_code(N), _code(T), _code(delay), _code(Δf), _code(ϕ))
    end
end

StudioADC(N, T, delay) = StudioADC(N, T, delay, "0", "0")
StudioADC(N, T) = StudioADC(N, T, "0")
StudioADC() = StudioADC("0", "0")

"""
    block = StudioSeqBlock(; name="", duration=nothing, gx, gy, gz, rf, adc)

One rendered Koma block. Gradients, RF, and ADC start off. `duration = nothing`
uses the longest event. A delay is a block with an explicit duration and no events.
"""
struct StudioSeqBlock
    name::String
    duration::Union{Nothing,StudioScript}
    gx::StudioGrad
    gy::StudioGrad
    gz::StudioGrad
    rf::StudioRF
    adc::StudioADC
    function StudioSeqBlock(;
        name::AbstractString="",
        duration=nothing,
        gx::StudioGrad=StudioGrad(),
        gy::StudioGrad=StudioGrad(),
        gz::StudioGrad=StudioGrad(),
        rf::StudioRF=StudioRF(),
        adc::StudioADC=StudioADC(),
    )
        new(String(name), duration === nothing ? nothing : _code(duration), gx, gy, gz, rf, adc)
    end
end

"""
    loop = StudioLoop(repetitions, children; name="", iterator=:i)

Repeats `children`. The iterator is an integer running from `0` to
`repetitions - 1`, available to expressions in the loop body. It must not clash
with a variable, `pi`, or an iterator of an enclosing loop.
"""
struct StudioLoop
    name::String
    repetitions::StudioScript
    iterator::Symbol
    children::Vector{Union{StudioLoop,StudioSeqBlock}}
    function StudioLoop(repetitions, children; name::AbstractString="", iterator::Symbol=:i)
        occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", String(iterator)) ||
            error("Invalid iterator name: $iterator")
        iterator == :pi && error("pi is reserved")
        new(String(name), _code(repetitions), iterator, StudioNode[child for child in children])
    end
end

const StudioNode = Union{StudioLoop,StudioSeqBlock}

"""
    studio = StudioSequence(variables, blocks; description="")

Editable sequence. `variables` are scripts. `blocks` is a tree of [`StudioLoop`](@ref)
and [`StudioSeqBlock`](@ref) nodes. `Sequence(studio)` unrolls the tree into a Koma sequence.
"""
struct StudioSequence
    description::String
    variables::Vector{StudioVariable}
    blocks::Vector{StudioNode}
    function StudioSequence(variables, blocks; description::AbstractString="")
        vars = StudioVariable[variable for variable in variables]
        names = Symbol[]
        for variable in vars
            variable.name in names && error("Duplicated variable $(variable.name)")
            push!(names, variable.name)
        end
        new(String(description), vars, StudioNode[block for block in blocks])
    end
end

StudioSequence(; description::AbstractString="", variables=StudioVariable[], blocks=StudioNode[]) =
    StudioSequence(variables, blocks; description)

"""
    studio = with_variable(studio::StudioSequence, name, script)

Return a sequence with `name` set to `script`. An existing variable keeps
its position and `readonly` flag.
"""
function with_variable(studio::StudioSequence, name, script)
    symbol = name isa Symbol ? name : Symbol(name)
    found = false
    variables = StudioVariable[]
    for variable in studio.variables
        if variable.name == symbol
            found = true
            push!(variables, StudioVariable(symbol, script; readonly=variable.readonly))
        else
            push!(variables, variable)
        end
    end
    found || push!(variables, StudioVariable(symbol, script))
    return StudioSequence(variables, studio.blocks; description=studio.description)
end

function Base.show(io::IO, studio::StudioSequence)
    print(io, "StudioSequence(")
    isempty(studio.description) || print(io, studio.description, ", ")
    print(io, length(studio.variables), " variables, ", length(studio.blocks), " blocks)")
end

"""
    env = variable_values(studio::StudioSequence)

Evaluate variable scripts in definition order. A script sees the variables
above it and does not see loop iterators. Values are numbers or vectors of numbers.
"""
function variable_values(variables::AbstractVector{<:StudioVariable})
    env = Dict{Symbol,Any}()
    for variable in variables
        haskey(env, variable.name) && error("Duplicated variable $(variable.name)")
        env[variable.name] = _eval_script(variable.name, variable.script, env)
    end
    return env
end

variable_values(studio::StudioSequence) = variable_values(studio.variables)

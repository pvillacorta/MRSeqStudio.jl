# Scripts and block fields share one whitelist interpreter. `Meta.parseall` only
# builds a tree; nothing is passed to Julia `eval`. A node that is not listed
# below is an error.

struct _ScriptReturn <: Exception
    value::Any
end

const _PI = Float64(pi)
const _GAMMA = Float64(γ)

# `^` on integers rejects a negative exponent. Literals stay integers so that
# `ones(3)` keeps a dimension, and these two operators promote to Float64.
_float(x::Real) = x isa Bool ? error("Expected a number") : Float64(x)
_float(x::AbstractArray{<:Real}) = Float64.(x)
_pow(a, b) = _float(a)^_float(b)
_dotpow(a, b) = _float(a).^_float(b)

function _dimension(x)
    x isa Bool && error("Dimension must be an integer, got $x")
    x isa Real && isinteger(x) && typemin(Int) <= x <= typemax(Int) ||
        error("Dimension must be an integer, got $x")
    return Int(x)
end

_ones(args...) = ones(map(_dimension, args)...)
_zeros(args...) = zeros(map(_dimension, args)...)

const _FUNCTIONS = Dict{Symbol,Function}(
    :+ => +,
    :- => -,
    :* => *,
    :/ => /,
    :^ => _pow,
    :.+ => .+,
    :.- => .-,
    :.* => .*,
    :./ => ./,
    :.^ => _dotpow,
    :(:) => (:),
    :ones => _ones,
    :zeros => _zeros,
    :collect => collect,
    :sin => sin,
    :cos => cos,
    :length => length,
)

"""
    code = StudioScript(source)

A whitelist script. `source` is checked when the code is built. Variables and
block fields both store a `StudioScript`.
"""
struct StudioScript
    source::String
    ast::Any
    function StudioScript(source::AbstractString)
        text = String(strip(source))
        isempty(text) && error("Empty expression")
        new(text, _parsed(text))
    end
end

_code(x::StudioScript) = x
_code(x::AbstractString) = StudioScript(x)

Base.show(io::IO, x::StudioScript) = print(io, x.source)

function _parsed(source::AbstractString)
    ast = try
        Meta.parseall(String(source))
    catch err
        error("Could not parse expression: $source. $(sprint(showerror, err))")
    end
    _check(ast, source)
    return ast
end

_bad(source) = error("Unsupported syntax: $source")

function _assign_name(name, source)
    name isa Symbol || _bad(source)
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", String(name)) || _bad(source)
    name === :pi && error("pi is reserved")
    return name
end

function _check(node, source)
    node isa LineNumberNode && return nothing
    node isa Nothing && return nothing
    if node isa Real
        node isa Bool && _bad(source)
        return nothing
    end
    node isa Symbol && return nothing
    node isa Expr || _bad(source)
    head = node.head
    if head === :toplevel || head === :block
        for arg in node.args
            _check(arg, source)
        end
    elseif head === :return
        length(node.args) == 1 || _bad(source)
        _check(node.args[1], source)
    elseif head === :(=)
        length(node.args) == 2 || _bad(source)
        _assign_name(node.args[1], source)
        _check(node.args[2], source)
    elseif head === :call
        _check_call(node, source)
    elseif head === :.
        _check_broadcast(node, source)
    elseif head === :vect
        for arg in node.args
            _check(arg, source)
        end
    elseif head === :incomplete
        error("Could not parse expression: $source")
    else
        _bad(source)
    end
    return nothing
end

function _check_call(node, source)
    isempty(node.args) && _bad(source)
    func = node.args[1]
    func isa Symbol || _bad(source)
    haskey(_FUNCTIONS, func) || error("Unknown function $func: $source")
    for arg in @view node.args[2:end]
        arg isa Expr && arg.head in (:kw, :parameters, :...) && _bad(source)
        _check(arg, source)
    end
    return nothing
end

function _check_broadcast(node, source)
    length(node.args) == 2 || _bad(source)
    func, args = node.args
    func isa Symbol || _bad(source)
    haskey(_FUNCTIONS, func) || error("Unknown function $func: $source")
    (args isa Expr && args.head === :tuple) || _bad(source)
    for arg in args.args
        _check(arg, source)
    end
    return nothing
end

function _child_env(env)
    child = Dict{Symbol,Any}()
    for (name, value) in env
        child[name] = value isa AbstractVector ? copy(value) : value
    end
    return child
end

function _eval_script(name::Symbol, code::StudioScript, env)
    return _finish("Script of $name", code.ast, _child_env(env), code.source)
end

function _eval_code(code::StudioScript, env)
    return _finish("Expression `$(code.source)`", code.ast, _child_env(env), code.source)
end

function _finish(what, ast, env, source)
    value = try
        _eval_node(ast, env, source)
    catch err
        err isa _ScriptReturn || rethrow()
        return _value(what, err.value)
    end
    return _value(what, value)
end

function _eval_node(node, env, source)
    node isa LineNumberNode && return nothing
    node isa Nothing && return nothing
    if node isa Real
        node isa Bool && _bad(source)
        return node
    end
    if node isa Symbol
        return _lookup(node, env, source)
    end
    node isa Expr || _bad(source)
    head = node.head
    if head === :toplevel || head === :block
        value = nothing
        for arg in node.args
            arg isa LineNumberNode && continue
            value = _eval_node(arg, env, source)
        end
        return value
    elseif head === :return
        length(node.args) == 1 || _bad(source)
        throw(_ScriptReturn(_eval_node(node.args[1], env, source)))
    elseif head === :(=)
        length(node.args) == 2 || _bad(source)
        name = _assign_name(node.args[1], source)
        value = _eval_node(node.args[2], env, source)
        env[name] = value
        return value
    elseif head === :call
        return _eval_call(node, env, source)
    elseif head === :.
        return _eval_broadcast(node, env, source)
    elseif head === :vect
        values = Float64[]
        for arg in node.args
            arg isa LineNumberNode && continue
            push!(values, _number(_eval_node(arg, env, source), source))
        end
        return values
    else
        _bad(source)
    end
end

function _eval_call(node, env, source)
    isempty(node.args) && _bad(source)
    func = node.args[1]
    func isa Symbol || _bad(source)
    haskey(_FUNCTIONS, func) || error("Unknown function $func: $source")
    values = Any[]
    for arg in @view node.args[2:end]
        arg isa Expr && arg.head in (:kw, :parameters, :...) && _bad(source)
        push!(values, _eval_node(arg, env, source))
    end
    return _FUNCTIONS[func](values...)
end

function _eval_broadcast(node, env, source)
    length(node.args) == 2 || _bad(source)
    func, args = node.args
    func isa Symbol || _bad(source)
    haskey(_FUNCTIONS, func) || error("Unknown function $func: $source")
    (args isa Expr && args.head === :tuple) || _bad(source)
    values = [_eval_node(arg, env, source) for arg in args.args]
    return broadcast(_FUNCTIONS[func], values...)
end

function _lookup(name::Symbol, env, source)
    haskey(env, name) && return env[name]
    name === :pi && return _PI
    name === :γ && return _GAMMA
    error("Unknown name $name in expression: $source")
end

function _number(value, source)
    value isa Bool && error("Expected a number in expression: $source")
    value isa Real || error("Expected a number in expression: $source")
    number = Float64(value)
    isfinite(number) || error("Non-finite value in expression: $source")
    return number
end

function _value(what, value::Real)
    value isa Bool && error("$what returned a $(typeof(value)); expected a number or a vector of numbers")
    number = Float64(value)
    isfinite(number) || error("$what returned a non-finite value")
    return number
end

function _value(what, value::AbstractVector{<:Real})
    out = Float64.(value)
    all(x -> !(x isa Bool), value) ||
        error("$what returned a $(typeof(value)); expected a number or a vector of numbers")
    all(isfinite, out) || error("$what returned a non-finite value")
    return out
end

_value(what, ::Nothing) = error("$what did not return a value")

function _value(what, value)
    error("$what returned a $(typeof(value)); expected a number or a vector of numbers")
end

function _integer_value(x::Real, what::AbstractString)
    isinteger(x) && typemin(Int) <= x <= typemax(Int) ||
        error("$what must be an integer, evaluated to $x")
    return Int(x)
end

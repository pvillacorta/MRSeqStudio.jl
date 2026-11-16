"""
    studio_panel(sequence::Observable{StudioSequence})

Bonito node for a studio sequence. The node updates when `sequence` changes.
[`StudioUI`](@ref) embeds it in a [`SeqStudioWindow`](@ref). KomaMRI can mount
the same node in its own window.
"""
struct _Pick
    variable::Symbol
    path::Vector{Int}
    field::Symbol
end

_Pick(path, field) = _Pick(Symbol(), path, field)

function studio_panel(sequence::Observable{StudioSequence})
    chosen = Observable("")
    revision = Observable(0)
    positions = Dict{String,Observable{Float64}}()
    body = map(sequence) do seq
        _body(seq, chosen, positions, revision)
    end
    script = map(sequence, chosen, revision) do seq, key, _
        _script_view(seq, _decode_pick(key), positions)
    end
    return DOM.div(body, script; class="p-3 koma-studio")
end

function _body(seq::StudioSequence, chosen, positions, revision)
    computed = Dict{Symbol,Any}()
    message = ""
    try
        computed = variable_values(seq)
    catch err
        message = sprint(showerror, err)
    end
    rows = map(seq.variables) do variable
        pick = _Pick(variable.name, Int[], :script)
        DOM.tr(
            DOM.td(_pick_button(string(variable.name), pick, chosen)),
            DOM.td(_pick_button(variable.script.source, pick, chosen)),
            DOM.td(string(get(computed, variable.name, ""))),
        )
    end
    parts = Any[DOM.h2("MR Seq Studio"; class="h5")]
    isempty(message) || push!(parts, DOM.p(message; class="text-danger"))
    push!(parts, DOM.table(
        DOM.thead(DOM.tr(DOM.th("Name"), DOM.th("Expression"), DOM.th("Value"))),
        DOM.tbody(rows...);
        class="table table-sm align-middle",
    ))
    push!(parts, DOM.h3("Blocks"; class="h6 mt-3"))
    push!(parts, _blocks(seq.blocks, Int[], chosen, positions, revision, computed))
    return DOM.div(parts...)
end

function _pick_button(label, pick::_Pick, chosen)
    key = _encode_pick(pick)
    return DOM.button(
        label;
        type="button",
        style="cursor:pointer; background:none; border:none; padding:0; color:inherit; font:inherit; text-align:left; text-decoration:underline",
        onclick=js"event => { event.preventDefault(); $(chosen).notify($(key)); }",
    )
end

_encode_pick(pick::_Pick) = pick.variable === Symbol() ?
    "field:$(join(pick.path, '.')),$(pick.field)" :
    "var:$(pick.variable)"

function _decode_pick(key::AbstractString)
    isempty(key) && return nothing
    if startswith(key, "var:")
        return _Pick(Symbol(key[5:end]), Int[], :script)
    end
    body = key[7:end]
    pathpart, field = split(body, ',')
    path = isempty(pathpart) ? Int[] : parse.(Int, split(pathpart, '.'))
    return _Pick(path, Symbol(field))
end

function _blocks(nodes, path, chosen, positions, revision, env)
    isempty(nodes) && return DOM.p("No blocks"; class="text-secondary")
    items = map(enumerate(nodes)) do (index, node)
        _node(node, vcat(path, index), chosen, positions, revision, env)
    end
    return DOM.ul(items...)
end

function _node(block::StudioSeqBlock, path, chosen, positions, revision, env)
    label = isempty(block.name) ? "block" : block.name
    return DOM.li(label, " ", _events(block, path, chosen))
end

function _node(loop::StudioLoop, path, chosen, positions, revision, env)
    label = isempty(loop.name) ? string(loop.iterator) : loop.name
    repetitions = _pick_button(loop.repetitions.source, _Pick(path, :repetitions), chosen)
    n = try
        _integer_value(_eval_code(loop.repetitions, env), "Repetitions of loop \"$(loop.name)\"")
    catch err
        return DOM.li(label, " × ", repetitions, " ", DOM.span(sprint(showerror, err); class="text-danger"))
    end
    if n < 0
        return DOM.li(label, " × ", repetitions, " ", DOM.span("Repetitions must be non-negative, got $n"; class="text-danger"))
    end
    obs, limit = _iterator_obs(positions, path, n)
    return DOM.li(
        label, " × ", repetitions,
        _slider(loop.iterator, obs, limit, revision),
        map(obs) do value
            child = copy(env)
            child[loop.iterator] = Float64(_iterator_value(value, limit))
            _blocks(loop.children, path, chosen, positions, revision, child)
        end,
    )
end

function _iterator_obs(positions, path, n)
    limit = max(n - 1, 0)
    obs = get!(positions, join(path, ".")) do
        Observable(0.0)
    end
    clamped = Float64(_iterator_value(obs[], limit))
    obs[] == clamped || (obs[] = clamped)
    return obs, limit
end

_iterator_value(value, limit) = clamp(round(Int, value), 0, limit)

function _slider(iterator, obs, limit, revision)
    return DOM.label(
        DOM.input(;
            type="range",
            min=0,
            max=limit,
            step=1,
            value=_iterator_value(obs[], limit),
            style="vertical-align:middle; width:8rem",
            oninput=js"""event => {
                const value = event.srcElement.valueAsNumber;
                if (value !== $(obs).value) {
                    $(obs).notify(value);
                    $(revision).notify($(revision).value + 1);
                }
            }""",
        ),
        map(obs) do value
            DOM.span(" $(iterator) = $(_iterator_value(value, limit))"; style="margin-left:0.4rem")
        end;
        style="margin-left:0.75rem",
    )
end

function _events(block::StudioSeqBlock, path, chosen)
    items = Pair{String,Symbol}[]
    _silent(block.gx) || push!(items, "Gx $(block.gx.A.source)" => :gx)
    _silent(block.gy) || push!(items, "Gy $(block.gy.A.source)" => :gy)
    _silent(block.gz) || push!(items, "Gz $(block.gz.A.source)" => :gz)
    block.rf.A.source == "0" || push!(items, "RF $(block.rf.A.source)" => :rf)
    block.adc.N.source == "0" || push!(items, "ADC $(block.adc.N.source)" => :adc)
    block.duration === nothing || push!(items, "duration $(block.duration.source)" => :duration)
    isempty(items) && return DOM.span("off"; class="text-secondary")
    row = Any[]
    for (index, (label, field)) in enumerate(items)
        index == 1 || push!(row, ", ")
        push!(row, _pick_button(label, _Pick(path, field), chosen))
    end
    return DOM.span(row...; class="text-secondary")
end

_silent(gr) = gr.A.source == "0" && gr.T.source == "0"

function _script_view(seq::StudioSequence, ::Nothing, positions)
    return DOM.p("Click a variable or a block field."; class="text-secondary mt-3")
end

function _script_view(seq::StudioSequence, pick::_Pick, positions)
    if pick.variable !== Symbol()
        index = findfirst(variable -> variable.name == pick.variable, seq.variables)
        index === nothing && return DOM.p("That script is no longer in the sequence."; class="text-secondary mt-3")
        variable = seq.variables[index]
        return DOM.div(
            DOM.h3(string(variable.name); class="h6 mt-3"),
            DOM.pre(variable.script.source; style="white-space:pre-wrap"),
        )
    end
    node = _node_at(seq.blocks, pick.path)
    node === nothing && return DOM.p("That field is no longer in the sequence."; class="text-secondary mt-3")
    return _parameter_view(seq, pick, node, positions)
end

struct _Frame
    env::Dict{Symbol,Any}
    iters::Vector{Pair{Symbol,Float64}}
end

function _frame_at(seq::StudioSequence, path, positions; bind_last_loop::Bool)
    env = variable_values(seq)
    iters = Pair{Symbol,Float64}[]
    nodes = seq.blocks
    for depth in eachindex(path)
        index = path[depth]
        1 <= index <= length(nodes) || return nothing
        node = nodes[index]
        last = depth == length(path)
        if node isa StudioLoop && (!last || bind_last_loop)
            n = _integer_value(_eval_code(node.repetitions, env), "Repetitions of loop \"$(node.name)\"")
            n < 0 && error("Repetitions of loop \"$(node.name)\" must be non-negative, got $n")
            key = join(path[1:depth], ".")
            raw = haskey(positions, key) ? positions[key][] : 0.0
            i = _iterator_value(raw, max(n - 1, 0))
            env = copy(env)
            env[node.iterator] = Float64(i)
            push!(iters, node.iterator => Float64(i))
        end
        last && return _Frame(env, iters)
        node isa StudioLoop || return nothing
        nodes = node.children
    end
    return nothing
end

function _parameter_view(seq::StudioSequence, pick::_Pick, node, positions)
    codes = _parameter_codes(node, pick.field)
    codes === nothing && return DOM.p("That field is no longer in the sequence."; class="text-secondary mt-3")
    frame = try
        _frame_at(seq, pick.path, positions; bind_last_loop=pick.field !== :repetitions)
    catch err
        return DOM.p(sprint(showerror, err); class="text-danger mt-3")
    end
    frame === nothing && return DOM.p("That field is no longer in the sequence."; class="text-secondary mt-3")
    rows = map(codes) do (name, code)
        DOM.tr(
            DOM.td(name),
            DOM.td(DOM.pre(code.source; class="mb-0", style="white-space:pre-wrap")),
            DOM.td(_value_of(code, frame.env)),
        )
    end
    heading = _node_title(node) * " · " * _field_name(pick.field)
    where = _iter_label(frame)
    return DOM.div(
        DOM.h3(isempty(where) ? heading : heading * " (" * where * ")"; class="h6 mt-3"),
        DOM.table(
            DOM.thead(DOM.tr(DOM.th("Parameter"), DOM.th("Script"), DOM.th("Value"))),
            DOM.tbody(rows...);
            class="table table-sm align-middle",
        ),
    )
end

function _value_of(code::StudioScript, env)
    try
        return _show_value(_eval_code(code, env))
    catch err
        return sprint(showerror, err)
    end
end

_iter_label(frame::_Frame) = join(["$(name)=$(Int(value))" for (name, value) in frame.iters], ", ")

_show_value(value::AbstractString) = value
_show_value(value) = string(value)

function _node_at(nodes, path)
    isempty(path) && return nothing
    index = path[1]
    1 <= index <= length(nodes) || return nothing
    node = nodes[index]
    length(path) == 1 && return node
    node isa StudioLoop || return nothing
    return _node_at(node.children, path[2:end])
end

_node_title(block::StudioSeqBlock) = isempty(block.name) ? "block" : block.name
_node_title(loop::StudioLoop) = isempty(loop.name) ? string(loop.iterator) : loop.name

function _field_name(field)
    field === :gx && return "Gx"
    field === :gy && return "Gy"
    field === :gz && return "Gz"
    field === :rf && return "RF"
    field === :adc && return "ADC"
    return string(field)
end

function _parameter_codes(block::StudioSeqBlock, field)
    field === :gx && return _grad_codes(block.gx)
    field === :gy && return _grad_codes(block.gy)
    field === :gz && return _grad_codes(block.gz)
    field === :rf && return _rf_codes(block.rf)
    field === :adc && return _adc_codes(block.adc)
    field === :duration && return block.duration === nothing ? nothing : [("duration", block.duration)]
    return nothing
end

_parameter_codes(loop::StudioLoop, field) = field === :repetitions ? [("repetitions", loop.repetitions)] : nothing

_grad_codes(gr::StudioGrad) = [("A", gr.A), ("T", gr.T), ("rise", gr.rise), ("fall", gr.fall), ("delay", gr.delay)]

_rf_codes(rf::StudioRF) = [("A", rf.A), ("T", rf.T), ("Δf", rf.Δf), ("delay", rf.delay), ("ϕ", rf.ϕ)]

_adc_codes(adc::StudioADC) = [("N", adc.N), ("T", adc.T), ("delay", adc.delay), ("Δf", adc.Δf), ("ϕ", adc.ϕ)]

"""
    w = SeqStudioWindow(app, seq, server)

A studio window. `w.seq` is the editable sequence, assigned like `w.seq[] = studio`.
`w.app` is the Bonito app that shows [`studio_panel`](@ref). `w.server` is set when
[`StudioUI`](@ref) serves the app in a browser.
"""
struct SeqStudioWindow
    app::App
    seq::Observable{StudioSequence}
    server::Base.RefValue{Union{Nothing,Server}}
end

studio(w::SeqStudioWindow) = w.seq

Base.show(io::IO, ::SeqStudioWindow) = print(io, "SeqStudioWindow()")

function Base.isopen(w::SeqStudioWindow)
    server = w.server[]
    return !isnothing(server) && Bonito.HTTPServer.isrunning(server)
end

function Base.close(w::SeqStudioWindow)
    server = w.server[]
    isnothing(server) || close(server)
    w.server[] = nothing
    return nothing
end

"""
    StudioUI(; seq=StudioSequence(), return_window=false, show_window=true, browser=false, host="127.0.0.1", port=8081)

Create a [`SeqStudioWindow`](@ref), as `KomaUI` creates a `KomaWindow`. The window
owns `w.seq`. [`studio_panel`](@ref) is the page of `w.app`.

`browser=true` serves the app at `host` and `port`. Otherwise `show_window=true`
displays `w.app` with Bonito. `show_window=false` only builds the window.
`return_window=true` returns it.

`seq` may be a [`StudioSequence`](@ref) or an `Observable` of one. An observable
is stored as `w.seq`, so later assignments are the same object.
"""
function StudioUI(;
    seq::Union{StudioSequence,Observable{StudioSequence}}=StudioSequence(),
    return_window::Bool=false,
    show_window::Bool=true,
    browser::Bool=false,
    host::AbstractString="127.0.0.1",
    port::Integer=8081,
)
    sequence = seq isa Observable ? seq : Observable(seq)
    app = App(studio_panel(sequence); title="MR Seq Studio")
    w = SeqStudioWindow(app, sequence, Ref{Union{Nothing,Server}}(nothing))
    if show_window
        if browser
            w.server[] = Server(w.app, String(host), Int(port))
            @info "Open StudioUI in your browser" url=Bonito.online_url(w.server[], "/")
        else
            display(w.app)
        end
    end
    return return_window ? w : nothing
end

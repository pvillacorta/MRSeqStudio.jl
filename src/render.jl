"""
    seq = Sequence(studio::StudioSequence)

Unroll a studio sequence into a Koma `Sequence`. Each [`StudioSeqBlock`](@ref)
becomes one block. Each [`StudioLoop`](@ref) repeats its children with the iterator
set to `0, 1, …, repetitions-1`.
"""
function Sequence(studio::StudioSequence)
    env = variable_values(studio)
    return Sequence([_render_node(block, env) for block in studio.blocks])
end

function _render_node(loop::StudioLoop, env)
    haskey(env, loop.iterator) &&
        error("Iterator $(loop.iterator) of loop \"$(loop.name)\" is already defined")
    n = _integer_value(_eval_code(loop.repetitions, env), "Repetitions of loop \"$(loop.name)\"")
    n < 0 && error("Repetitions of loop \"$(loop.name)\" must be non-negative, got $n")
    parts = Sequence[]
    for i in 0:(n - 1)
        child_env = copy(env)
        child_env[loop.iterator] = Float64(i)
        for child in loop.children
            push!(parts, _render_node(child, child_env))
        end
    end
    return Sequence(parts)
end

function _render_node(block::StudioSeqBlock, env)
    gx = _render_grad(block.gx, env)
    gy = _render_grad(block.gy, env)
    gz = _render_grad(block.gz, env)
    rf = _render_rf(block.rf, env)
    adc = _render_adc(block.adc, env)
    GR = reshape([gx, gy, gz], :, 1)
    RF = reshape([rf], 1, :)
    block.duration === nothing && return Sequence(GR, RF, [adc])
    duration = _eval_code(block.duration, env)
    duration < 0 && error("Duration of block \"$(block.name)\" must be non-negative, got $duration s")
    natural = max(dur(gx), dur(gy), dur(gz), dur(rf), dur(adc))
    duration < natural &&
        error("Duration of block \"$(block.name)\" ($(duration) s) is shorter than its events ($(natural) s)")
    return Sequence(GR, RF, [adc], [duration])
end

function _render_grad(gr::StudioGrad, env)
    return Grad(
        _eval_code(gr.A, env),
        _eval_code(gr.T, env),
        _eval_code(gr.rise, env),
        _eval_code(gr.fall, env),
        _eval_code(gr.delay, env),
    )
end

function _render_rf(rf::StudioRF, env)
    return RF(
        _eval_code(rf.A, env),
        _eval_code(rf.T, env),
        _eval_code(rf.Δf, env),
        _eval_code(rf.delay, env);
        ϕ=_eval_code(rf.ϕ, env),
        use=rf.use,
    )
end

function _render_adc(adc::StudioADC, env)
    samples = _integer_value(_eval_code(adc.N, env), "ADC samples")
    samples < 0 && error("ADC samples must be non-negative, got $samples")
    return ADC(
        samples,
        _eval_code(adc.T, env),
        _eval_code(adc.delay, env),
        _eval_code(adc.Δf, env),
        _eval_code(adc.ϕ, env),
    )
end

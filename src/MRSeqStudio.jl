module MRSeqStudio

using Reexport
@reexport using Bonito
@reexport using KomaMRIBase
import KomaMRIBase: RFUse, Sequence

include("script.jl")
include("sequence.jl")
include("render.jl")
include("ui.jl")

export StudioScript, StudioVariable, StudioGrad, StudioRF, StudioADC
export StudioSeqBlock, StudioLoop, StudioSequence
export variable_values, with_variable, studio_panel, SeqStudioWindow, StudioUI

"""
    studio(w)

Observable of a window's [`StudioSequence`](@ref). For a [`SeqStudioWindow`](@ref)
this is `w.seq`. KomaMRI adds the method for a Koma window when both packages
are loaded.
"""
studio(w) = error("`studio` needs a `SeqStudioWindow`, or `using KomaMRI` for a Koma window.")

export studio

end

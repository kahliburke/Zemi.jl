# A plugin for the tests written for another version of the plugin interface, which Zemi refuses.
module ZemiOldPlugin

__precompile__(false)                   # the tests load it from its source, uncompiled

import Zemi

poll(run) = nothing

__init__() = Zemi.record_source!("zz-old"; label = "Written for another Zemi", every = 60, poll, api = Zemi.PLUGIN_API + 1)

end

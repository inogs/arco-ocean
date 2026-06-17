# Load provided Leonardo modules.
# Notice: **don't** load other modules beforehand (e.g. certain other versions of cmake), as in tests bugged pigz/tar made the build fail.

export LEONARDO_MODULES_DEFINED=true

function load_modules {
    module load openmpi/4.1.6--gcc--12.2.0-cuda-12.2
    export LEONARDO_MODULES_LOADED=true
}

function unload_modules {
    module unload openmpi/4.1.6--gcc--12.2.0-cuda-12.2
    export LEONARDO_MODULES_LOADED=false
}

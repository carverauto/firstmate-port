// Stand-in for the file the :phoenix_live_view compiler generates at
// _build/$MIX_ENV/phoenix-colocated/firstmate_port/index.js during
// `mix compile`.
//
// This repo has no colocated hooks or ColocatedJS, so the compiler output is
// exactly the empty-hooks module below (verified against a local prod
// compile). The Bazel esbuild step resolves the `phoenix-colocated/...`
// import (NODE_PATH) from this file instead of a Mix build tree.
//
// If a colocated hook or script is ever added under lib/, the real compiler
// output will no longer match this stub: the Bazel image would bundle empty
// hooks while `mix assets.deploy` works. Revisit this file then (or teach the
// release action to carry the compiler output through).
export const hooks = {};
export default {};

// @trace order:1757-n45b
//
// The observatorium Worker's script. It runs FIRST only for
// /tillandsias/cloudflare/* (wrangler.jsonc assets.run_worker_first); every
// other request goes straight to the static site and never reaches this file.
//
// The page is the ONE canonical relay page (1505-kc5f), bundled as text by
// wrangler's Text rule, so there is no second copy to drift.
import PAGE from "../../assets/cloudflare-relay/index.html";
import { makeHandler, RelayState } from "./relay.js";

export { RelayState };
export default makeHandler(PAGE);

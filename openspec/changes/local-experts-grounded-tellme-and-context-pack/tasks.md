# Tasks — local-experts-grounded-tellme-and-context-pack

How to read this list:

- Packet orders are in brackets.
- Tasks run in dependency order, top to bottom.
- Each task closes on the fixture or measurement named in its packet's exit criteria.
- Write that fixture first and show it failing on today's code.

## 1. Facts the experts can retrieve (p1)

- [ ] 1.1 `cheatsheets/runtime/forge-constraints.md` with provenance; regenerate INDEX.md; both cheatsheet guards pass [1816-iyyc]
- [ ] 1.2 Groundtruth forge-awareness cases plus a fixture project that is not Tillandsias. They fail on today's tree; bind them to `litmus:expert-groundtruth-harness` [1821-xcwc]

## 2. Grounding (p1)

- [ ] 2.1 Context pack built at forge launch from the project's own declarations, at most 4800 bytes, first and byte-identical in `domain_synthesis_prompt` and tellme [1815-tei4]
- [ ] 2.2 tellme sends howto/about to expert-serve; the grep fallback drops the general-knowledge sentence and honours `TILLANDSIAS_INFERENCE_MODEL` [1814-x78v]
- [ ] 2.3 Quick skips decomposition in `run_grounded`; re-measure warm Quick on macuahuitl and record the result on 965-hz3f [1817-wq7y]

## 3. Budget, cache, refusal (p2)

- [ ] 3.1 Explicit context window for each model size; retrieved context capped by a token budget [1818-uiar]
- [ ] 3.2 expert-serve answer cache keyed by index revision, model and normalised query [1819-njan]
- [ ] 3.3 Refusal by score margin plus word overlap, measured against the floor rule on the refusal corpora [1820-m2kq]

## 4. Retrieval quality and one client (p3)

- [ ] 4.1 Hybrid BM25 + dense retrieval with RRF, a reranker on Fine only, YAML chunks prefixed with breadcrumbs [1822-dmwz]
- [ ] 4.2 One expert client for every front-end, plus a guard that refuses direct inference HTTP calls [1823-4kwh]

## 5. Close

- [ ] 5.1 Live arm on story 1813-54df: in a forge on a project that is not Tillandsias, `tellme howto "run a database container"` cites forge-constraints and does not recommend docker

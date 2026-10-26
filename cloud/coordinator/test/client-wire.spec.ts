// 1826-gi8e criterion (b): replay the Rust client's exact request bodies
// (fixtures/client-ops.json, pinned on the Rust side by
// client_ops_fixture_matches_the_builders) through the real Worker, and check
// every response field the client reads is there with the type it expects.
// This is the pre-deploy proof; the live round-trip belongs to 1830's closure.

import { beforeEach, describe, expect, it } from "vitest";
import fixture from "./fixtures/client-ops.json";
import { freshNs, op, setupAccess } from "./helpers";

type Step = {
  name: string;
  who: string;
  request: Record<string, unknown>;
  status: number;
  reads: Record<string, string>;
  orders?: string[];
};

const at = (v: any, path: string) => path.split(".").reduce((o, k) => (o == null ? undefined : o[k]), v);
const kind = (v: unknown) => (Array.isArray(v) ? "array" : v === null ? "null" : typeof v);

describe("the Rust client's wire shapes against the Worker", () => {
  beforeEach(setupAccess);

  it("every step answers with the status and fields the client reads", async () => {
    const ns = freshNs();
    const run = `${Date.now().toString(36)}`;
    const vars: Record<string, string> = { NS: ns, HEAD_SHA: "0123456789abcdef0123456789abcdef01234567" };
    const steps = (fixture as unknown as { steps: Step[] }).steps;
    expect(steps.length).toBe(11);
    for (const s of steps) {
      const body = JSON.parse(
        JSON.stringify(s.request).replace(/"NS"|"HEAD_SHA"|\{\{claim\.token\}\}/g, (m) =>
          m.startsWith('"') ? JSON.stringify(vars[m.slice(1, -1)]) : vars["claim.token"],
        ),
      );
      // Distinct identities per run keep rate buckets from leaking between tests.
      const res = await op(body, { who: `${s.who}-${run}` });
      expect(res.status, `${s.name}: ${JSON.stringify(res.body)}`).toBe(s.status);
      for (const [path, type] of Object.entries(s.reads)) {
        expect(kind(at(res.body, path)), `${s.name} reads ${path}`).toBe(type);
      }
      if (s.orders) {
        expect(res.body.claims.map((c: { order: string }) => c.order).sort(), s.name).toEqual(s.orders);
      }
      if (s.name === "claim") vars["claim.token"] = res.body.token;
      if (s.name === "recv") expect(res.body.msgs[0].body).toBe("hello fleet");
      if (s.name === "release") expect(res.body.released).toBe(true);
    }
  });
});

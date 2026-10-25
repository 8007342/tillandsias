import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        // Test-only values: a fake team domain whose certs the tests serve,
        // and a small bucket so the 429 arm is reachable.
        bindings: {
          ACCESS_TEAM_DOMAIN: "fleet-test.cloudflareaccess.com",
          ACCESS_AUD: "test-aud",
          RATE_LIMIT_PER_MIN: "30",
          STALE_AFTER_S: "900",
        },
      },
    }),
  ],
});

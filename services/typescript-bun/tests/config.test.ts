import { describe, expect, test } from "bun:test";

import { loadConfig } from "../src/config.ts";

describe("loadConfig", () => {
  test("normalizes trailing slashes from inference URLs", () => {
    const config = loadConfig({ INFERENCE_URL: "http://inference.example:9000///" });

    expect(config.inferenceUrl).toBe("http://inference.example:9000");
  });
});

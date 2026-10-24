import { describe, expect, it } from "vitest";

import { jobIdFromSearch, withJobId } from "./joblink";

const ID = "6f1d2c3a-4b5e-4f60-8a71-92b3c4d5e6f7";

describe("jobIdFromSearch", () => {
  it("reads a job id, normalising case and whitespace", () => {
    expect(jobIdFromSearch(`?job=${ID}`)).toBe(ID);
    expect(jobIdFromSearch(`?x=1&job=${ID.toUpperCase()}%20`)).toBe(ID);
  });

  it("ignores missing or malformed ids", () => {
    for (const search of ["", "?job=", "?job=abc", `?job=${ID}x`, "?job=../../etc"]) {
      expect(jobIdFromSearch(search)).toBeNull();
    }
  });
});

describe("withJobId", () => {
  it("sets and removes the job parameter, keeping others", () => {
    expect(withJobId("https://r.example/?a=1", ID)).toBe(`https://r.example/?a=1&job=${ID}`);
    expect(withJobId(`https://r.example/?job=${ID}&a=1`, null)).toBe("https://r.example/?a=1");
  });
});

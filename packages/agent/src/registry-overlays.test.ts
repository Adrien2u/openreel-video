import { describe, it, expect } from "vitest";
import { HeadlessHost } from "./headless-host";
import { executeTool } from "./executor";
import { getTool } from "./registry";
import { makeEmptyProject } from "./test-fixtures";
import type { Project } from "@openreel/core/types/project";

describe("list_overlays", () => {
  function projectWithOverlays(): Project {
    const empty = makeEmptyProject() as unknown as Record<string, unknown>;
    return {
      ...empty,
      timeline: {
        ...(empty.timeline as object),
        subtitles: [{ id: "s1", text: "Hello there", startTime: 1, endTime: 2.5 }],
      },
      textClips: [
        { id: "t1", trackId: "tt", startTime: 0.5, duration: 3, text: "Title", style: {}, transform: {}, keyframes: [] },
      ],
    } as unknown as Project;
  }

  it("is a read-only tool", () => {
    expect(getTool("list_overlays")?.readOnly).toBe(true);
  });

  it("lists text clips and subtitles with their timings in seconds", async () => {
    const res = await executeTool("list_overlays", {}, new HeadlessHost(projectWithOverlays()));
    expect(res.ok).toBe(true);
    expect(res.data).toEqual({
      textClips: [{ id: "t1", trackId: "tt", text: "Title", startSec: 0.5, endSec: 3.5, durationSec: 3 }],
      subtitles: [{ id: "s1", text: "Hello there", startSec: 1, endSec: 2.5, durationSec: 1.5 }],
    });
  });

  it("returns empty lists for a project with no overlays", async () => {
    const res = await executeTool("list_overlays", {}, new HeadlessHost(makeEmptyProject()));
    expect(res.data).toEqual({ textClips: [], subtitles: [] });
  });
});

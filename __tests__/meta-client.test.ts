import { afterEach, describe, expect, it, vi } from "vitest";

import { getUserInfo } from "@/lib/meta/client";

describe("getUserInfo", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("falls back to /me when Meta cannot load the OAuth user ID", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            error: {
              message: "Unsupported get request",
              type: "IGApiException",
              code: 100,
              error_subcode: 33,
            },
          }),
          { status: 400 }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            id: "resolved-id",
            user_id: "professional-id",
            username: "ashcashlearns",
          }),
          { status: 200 }
        )
      );

    await expect(getUserInfo("token", "oauth-id")).resolves.toMatchObject({
      username: "ashcashlearns",
      user_id: "professional-id",
    });

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[0]?.[0]).toContain("/oauth-id?");
    expect(fetchMock.mock.calls[1]?.[0]).toContain("/me?");
  });
});

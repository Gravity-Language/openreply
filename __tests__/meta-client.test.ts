import { afterEach, describe, expect, it, vi } from "vitest";

import { getLongLivedToken, getUserInfo } from "@/lib/meta/client";

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

describe("getLongLivedToken", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
  });

  it("exchanges the short-lived token and preserves Meta's returned lifetime", async () => {
    vi.stubEnv("INSTAGRAM_APP_SECRET", "app-secret");
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(
        JSON.stringify({ access_token: "long-token", expires_in: 5_184_000 }),
        { status: 200 }
      )
    );

    await expect(getLongLivedToken("short-token")).resolves.toEqual({
      accessToken: "long-token",
      expiresIn: 5_184_000,
    });

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      "https://graph.instagram.com/access_token"
    );
    const request = fetchMock.mock.calls[0]?.[1];
    expect(request?.method).toBe("POST");
    expect(request?.headers).toEqual({
      "Content-Type": "application/x-www-form-urlencoded",
    });
    const body = new URLSearchParams(String(request?.body));
    expect(body.get("grant_type")).toBe("ig_exchange_token");
    expect(body.get("client_secret")).toBe("app-secret");
    expect(body.get("access_token")).toBe("short-token");
  });
});

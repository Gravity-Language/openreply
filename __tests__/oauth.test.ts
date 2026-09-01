import { describe, expect, it, vi, beforeEach } from "vitest";
import {
  createOAuthState,
  decryptToken,
  encryptToken,
  exchangeCodeForToken,
  verifyOAuthState,
} from "../lib/meta/oauth";

beforeEach(() => {
  vi.stubEnv("NEXTAUTH_SECRET", "test-secret-with-enough-length");
  vi.stubEnv(
    "ENCRYPTION_KEY",
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  );
});

describe("OAuth state and token encryption", () => {
  it("round-trips encrypted tokens", () => {
    const encrypted = encryptToken("long-lived-token");
    expect(encrypted).not.toBe("long-lived-token");
    expect(decryptToken(encrypted)).toBe("long-lived-token");
  });

  it("signs and verifies Instagram OAuth state", () => {
    const state = createOAuthState("workspace_123");
    expect(verifyOAuthState(state)?.workspaceId).toBe("workspace_123");
  });

  it("rejects tampered OAuth state", () => {
    const state = createOAuthState("workspace_123");
    expect(verifyOAuthState(`${state}tampered`)).toBeNull();
  });

  it("uses the Instagram Login code-exchange token as a long-lived token", async () => {
    vi.stubEnv("INSTAGRAM_APP_ID", "app-id");
    vi.stubEnv("INSTAGRAM_APP_SECRET", "app-secret");
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(
        JSON.stringify({ access_token: "short-token", user_id: 123 }),
        { status: 200 }
      )
    );

    await expect(
      exchangeCodeForToken("code", "https://example.com/callback")
    ).resolves.toEqual({
      accessToken: "short-token",
      userId: "123",
      expiresIn: 5_184_000,
    });

    fetchMock.mockRestore();
  });
});

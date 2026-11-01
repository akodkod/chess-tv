import { credential, id } from "@chess-tv/protocol"
import { z } from "zod"
const claimSchema = z.strictObject({ challengeId: id, token: credential, expiresAt: z.number() })
const pollSchema = z.strictObject({
  state: z.enum(["waiting", "claimed", "confirmed", "rejected"]),
  expiresAt: z.number(),
  pairingId: id.optional(),
  credential: credential.optional(),
})
export const savedSchema = z.strictObject({
  relay: z.string(),
  device: z.strictObject({ pairingId: id, credential }).optional(),
  claim: claimSchema.optional(),
  revocationPending: z.boolean().optional(),
})
export type Saved = z.infer<typeof savedSchema>
export class Pairing {
  saved: Saved
  constructor(
    private relay: string,
    private persist: (saved: Saved) => Promise<void>,
  ) {
    this.saved = { relay }
  }
  private async request(path: string, method: string, body?: unknown, token?: string) {
    return fetch(this.relay + path, {
      method,
      cache: "no-store",
      signal: AbortSignal.timeout(8000),
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
  }
  async claim(code: string) {
    if (this.saved.device || this.saved.claim)
      throw new Error("Finish or wait for the current pairing before starting another.")
    const response = await this.request("/v1/pairing/claim", "POST", { code })
    if (!response.ok)
      throw new Error("Code could not be claimed. Request a new TV code; do not reuse this one.")
    const claim = claimSchema.parse(await response.json())
    this.saved = { relay: this.relay, claim }
    await this.persist(this.saved)
  }
  async poll() {
    const claim = this.saved.claim
    if (!claim) return
    if (claim.expiresAt <= Date.now()) {
      await this.expire()
      throw new Error("Pairing expired. Request a new TV code.")
    }
    const response = await this.request(
      `/v1/pairing/${claim.challengeId}`,
      "GET",
      undefined,
      claim.token,
    )
    if ([401, 404].includes(response.status)) {
      await this.expire()
      throw new Error("Pairing is no longer available. Request a new TV code.")
    }
    if (!response.ok)
      throw new Error("Cannot check pairing status. Retrying until the code expires.")
    const result = pollSchema.parse(await response.json())
    if (result.state === "rejected") {
      await this.expire()
      throw new Error("Pairing declined on TV. Request a new code.")
    }
    if (result.state === "confirmed") {
      const device = z
        .strictObject({ pairingId: id, credential })
        .parse({ pairingId: result.pairingId, credential: result.credential })
      const next = { relay: this.relay, device }
      // Keep the claim retryable if durable credential storage fails.
      await this.persist(next)
      this.saved = next
    }
  }
  private async expire() {
    this.saved = { relay: this.relay }
    await this.persist(this.saved)
  }
  async unpair() {
    const device = this.saved.device
    if (!device) {
      await this.expire()
      return
    }
    this.saved.revocationPending = true
    await this.persist(this.saved)
    const response = await this.request("/v1/pairing", "DELETE", undefined, device.credential)
    // 401 proves this credential no longer grants access (e.g. TV already revoked).
    if (response.status !== 204 && response.status !== 401)
      throw new Error("Remote revocation incomplete. Reconnect and retry Unpair.")
    await this.expire()
  }
}

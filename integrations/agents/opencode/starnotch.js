// Starnotch for opencode: shows opencode's sessions in the Starnotch island and answers its
// permission prompts from there. Installed by Starnotch's setup into
// ~/.config/opencode/plugins/starnotch.js; Settings › What's set up removes it again.
//
// It talks only to the Starnotch app on this Mac, through its socket in
// ~/Library/Application Support/Starnotch (folder 0700, socket yours). It never allows on its own:
// with no app, or no click within 70 s, opencode's own prompt stays in charge. Nothing is written.

import fs from "node:fs"
import net from "node:net"
import os from "node:os"
import path from "node:path"

function socketPath() {
  const candidates = process.env.STARNOTCH_SOCKET
    ? [process.env.STARNOTCH_SOCKET]
    : ["Starnotch", "NotchSwitcher"].map((name) => path.join(os.homedir(), "Library/Application Support", name, "approvals.sock"))
  const uid = process.getuid?.()
  for (const candidate of candidates) {
    try {
      const sock = fs.statSync(candidate)
      const dir = fs.statSync(path.dirname(candidate))
      if (sock.isSocket() && sock.uid === uid && dir.uid === uid && (dir.mode & 0o777) === 0o700) return candidate
    } catch {}
  }
  return null
}

// Sends one line. `wait`: keeps the connection open (a newline every 0.2 s) until the island
// answers; resolves with the answer, or null. `cancel` ends the wait early.
function send(message, wait = false) {
  const sock = socketPath()
  if (!sock) return { done: Promise.resolve(null), cancel() {} }
  let finish = () => {}
  const done = new Promise((resolve) => {
    const client = net.createConnection(sock)
    let data = ""
    let over = false
    let keep = null
    const timer = setTimeout(() => finish(null), wait ? 70_000 : 2_000)
    finish = (value) => {
      if (over) return
      over = true
      clearTimeout(timer)
      if (keep) clearInterval(keep)
      client.destroy()
      resolve(value)
    }
    client.on("connect", () => {
      client.write(JSON.stringify({ starnotch_provider: "opencode", starnotch_pid: process.pid, ...message }) + "\n")
      if (wait) keep = setInterval(() => client.write("\n"), 200)
      else client.end()
    })
    client.on("data", (chunk) => {
      data += chunk
      if (data.length > 65_536) finish(null)
    })
    client.on("end", () => finish(data.trim() || null))
    client.on("error", () => finish(null))
  })
  return { done, cancel: () => finish(null) }
}

export const StarnotchPlugin = async ({ directory, serverUrl }) => {
  const pending = new Map()

  async function reply(id, sessionID, answer) {
    const headers = { "content-type": "application/json" }
    if (process.env.OPENCODE_SERVER_PASSWORD) {
      const user = process.env.OPENCODE_SERVER_USERNAME || "opencode"
      headers.authorization = "Basic " + Buffer.from(`${user}:${process.env.OPENCODE_SERVER_PASSWORD}`).toString("base64")
    }
    const base = new URL(serverUrl)
    const query = `?directory=${encodeURIComponent(directory)}`
    const tries = [
      [`permission/${encodeURIComponent(id)}/reply${query}`, { reply: answer }],
      [`session/${encodeURIComponent(sessionID)}/permissions/${encodeURIComponent(id)}${query}`, { response: answer }],
    ]
    for (const [route, body] of tries) {
      try {
        const res = await fetch(new URL(route, base), { method: "POST", headers, body: JSON.stringify(body) })
        if (res.ok) return
      } catch {}
    }
  }

  async function ask(permission) {
    const id = permission.id
    if (!id || pending.has(id)) return
    const request = send({
      hook_event_name: "permission.asked",
      session_id: permission.sessionID,
      cwd: directory,
      permission: permission.permission ?? permission.type,
      patterns: permission.patterns ?? [permission.pattern].flat().filter(Boolean),
      metadata: permission.metadata ?? {},
      title: permission.title,
    }, true)
    pending.set(id, request)
    const answer = await request.done
    pending.delete(id)
    let decision = null
    try { decision = JSON.parse(answer ?? "null")?.reply } catch {}
    if (["once", "always", "reject"].includes(decision)) await reply(id, permission.sessionID, decision)
  }

  return {
    event: async ({ event }) => {
      const p = event.properties ?? {}
      switch (event.type) {
        case "session.created":
        case "session.updated":
        case "session.deleted": {
          const info = p.info ?? {}
          send({ hook_event_name: event.type, session_id: info.id, cwd: info.directory ?? directory,
                 title: info.title, parent_id: info.parentID })
          break
        }
        case "session.status":
          send({ hook_event_name: "session.status", session_id: p.sessionID, cwd: directory, status: p.status?.type })
          break
        case "session.idle":
          send({ hook_event_name: "session.idle", session_id: p.sessionID, cwd: directory })
          break
        case "permission.asked":
        case "permission.updated":
          ask(p)
          break
        case "permission.replied": {
          // Answered in opencode itself: the island's card goes away.
          const id = p.requestID ?? p.permissionID
          pending.get(id)?.cancel()
          send({ hook_event_name: "permission.replied", session_id: p.sessionID, cwd: directory })
          break
        }
      }
    },
    "tool.execute.before": async (input, output) => {
      send({ hook_event_name: "tool", session_id: input.sessionID, cwd: directory, tool: input.tool, input: output?.args ?? {} })
    },
  }
}

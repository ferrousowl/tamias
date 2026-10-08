// The owner's approval channel: a dedicated Telegram bot, long-polled here. Only messages from the
// configured owner id that are exactly "approve N" or "reject N" do anything; everything else gets
// a one-line help reply (or nothing, for strangers). Runs the same calls as `owner.mjs`.
//
// Config (outside the repo, it identifies a person): ~/.config/tamias/notify.json
//   { "enabled": true, "tokenFile": "~/.config/tamias/approvals-token", "chatId": "<owner chat>", "ownerId": <owner user id> }
//   TAMIAS_NETWORK=mainnet node approvals.mjs
import fs from "fs";
import os from "os";
import path from "path";
import { toHex } from "viem";
import { loadConfig, clients, TAMIAS_ABI, fees, log } from "./lib.mjs";

const N = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".config/tamias/notify.json"), "utf8"));
const token = fs.readFileSync(N.tokenFile.replace(/^~/, os.homedir()), "utf8").trim();
const API = `https://api.telegram.org/bot${token}`;
const OFFSET = path.join(os.homedir(), ".config/tamias/approvals-offset");
const cfg = loadConfig();
const { pub, wallet } = clients(cfg);
const owner = wallet(cfg.keys.owner);
const T = { address: cfg.tamias, abi: TAMIAS_ABI };
const STATUS = ["pending", "approved", "rejected"];

async function tg(method, body) {
  const r = await fetch(`${API}/${method}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  return r.json();
}
const reply = (text) => tg("sendMessage", { chat_id: N.chatId, text, disable_web_page_preview: true });

async function decide(verb, id, from) {
  const p = await pub.readContract({ ...T, functionName: "getProposal", args: [BigInt(id)] }).catch(() => null);
  if (!p) return reply(`There is no proposal #${id}.`);
  if (p.status !== 0) return reply(`Proposal #${id} is already ${STATUS[p.status]}.`);
  const note = toHex(new TextEncoder().encode(JSON.stringify({ v: 1, app: "tamias", by: "owner", decision: verb, proposal: id, via: "telegram" })));
  const fn = verb === "approve" ? "approveProposal" : "rejectProposal";
  try {
    await pub.simulateContract({ ...T, functionName: fn, args: [BigInt(id), note], account: owner.account });
    const hash = await owner.writeContract({ ...T, functionName: fn, args: [BigInt(id), note], ...(await fees(pub)) });
    const rc = await pub.waitForTransactionReceipt({ hash });
    log(`${verb} #${id} by ${from}: ${hash} (${rc.status})`);
    await reply(`${verb === "approve" ? "Approved" : "Rejected"} #${id}. ${rc.status === "success" ? "Done" : "Reverted"}: ${cfg.explorer}/tx/${hash}`);
  } catch (e) {
    const msg = e.shortMessage ?? e.message;
    log(`${verb} #${id} failed: ${msg}`);
    await reply(`Could not ${verb} #${id}: ${String(msg).slice(0, 200)}`);
  }
}

log(`approvals bot polling for ${cfg.network} treasury ${cfg.tamias}`);
let offset = fs.existsSync(OFFSET) ? Number(fs.readFileSync(OFFSET, "utf8")) : 0;
for (;;) {
  let res;
  try {
    res = await tg("getUpdates", { offset, timeout: 50, allowed_updates: ["message"] });
  } catch (e) {
    log(`poll failed: ${e.message}`);
    await new Promise((r) => setTimeout(r, 15_000));
    continue;
  }
  if (!res.ok) { log(`poll error: ${res.description}`); await new Promise((r) => setTimeout(r, 30_000)); continue; }
  for (const u of res.result) {
    offset = u.update_id + 1;
    fs.writeFileSync(OFFSET, String(offset));
    const m = u.message;
    if (!m?.from || m.from.id !== Number(N.ownerId) || String(m.chat.id) !== String(N.chatId)) continue; // strangers: silence
    const t = (m.text ?? "").trim();
    const hit = /^(approve|reject) (\d{1,6})$/i.exec(t);
    if (hit) await decide(hit[1].toLowerCase(), Number(hit[2]), m.from.id);
    else if (t !== "/start") await reply('Reply exactly "approve N" or "reject N" to decide proposal #N.');
  }
}

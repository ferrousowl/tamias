// Tell the owner when the agent escalates. Off unless ~/.config/tamias/notify.json exists:
//   { "enabled": true, "tokenFile": "/path/to/telegram-bot-token", "chatId": "…" }
// Kept outside the repository: the chat id identifies a person.
import fs from "fs";
import os from "os";
import path from "path";
import { log } from "./lib.mjs";

const FILE = path.join(os.homedir(), ".config/tamias/notify.json");

export async function notifyOwner(text) {
  if (!fs.existsSync(FILE)) return false;
  const n = JSON.parse(fs.readFileSync(FILE, "utf8"));
  if (!n.enabled) return false;
  const token = fs.readFileSync(n.tokenFile, "utf8").trim();
  const body = new URLSearchParams({ chat_id: String(n.chatId), text: text.slice(0, 3900), disable_web_page_preview: "true" });
  try {
    const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, { method: "POST", body });
    if (!r.ok) log(`notify failed: HTTP ${r.status}`);
    return r.ok;
  } catch (e) {
    log(`notify failed: ${e.message}`);
    return false;
  }
}

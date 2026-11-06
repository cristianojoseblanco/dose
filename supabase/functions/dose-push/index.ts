// Dose · função que manda o lembrete no celular na hora de cada dose.
// Chamada a cada 5 minutos pelo pg_cron. Segredos: VAPID_PUBLIC, VAPID_PRIVATE, CRON_SECRET.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const TZ = "America/Sao_Paulo";
const WINDOW = 15;   // minutos depois do horário em que o aviso ainda sai
const NUDGE = 60;    // segundo aviso se ninguém marcou a dose

function nowSP() {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
    .formatToParts(new Date()).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, min: +p.hour * 60 + +p.minute };
}
const toMin = (t: string) => { const [h, m] = t.split(":").map(Number); return h * 60 + m; };
const addDays = (d: string, n: number) => { const x = new Date(d + "T12:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const unit = (m: any) => { const f = (m.form || "comprimido").toLowerCase(); return m.dose === 1 ? f : f.endsWith("l") ? f + "es" : f + "s"; };

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) return new Response("não autorizado", { status: 401 });
  webpush.setVapidDetails("mailto:dose@exemplo.com", Deno.env.get("VAPID_PUBLIC")!, Deno.env.get("VAPID_PRIVATE")!);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { date, min } = nowSP();

  const { data: subs } = await sb.from("push_subs").select("endpoint,household_id,sub");
  if (!subs?.length) return Response.json({ sent: 0 });
  const homes = [...new Set(subs.map((s) => s.household_id))];
  const { data: meds } = await sb.from("meds").select("id,household_id,data").in("household_id", homes);
  const { data: sets } = await sb.from("settings").select("household_id,data").in("household_id", homes);
  const since = addDays(date, -60);
  const { data: logs } = await sb.from("dose_log").select("med_id,sched,taken").in("household_id", homes).gte("sched", since);
  const who = (h: string) => (sets?.find((s) => s.household_id === h)?.data?.profile?.patient || "").trim();

  const jobs: { key: string; h: string; title: string; body: string }[] = [];
  for (const r of meds || []) {
    const m = r.data, s = m?.sched;
    if (!s || (m.until && m.until < date)) continue;
    const L = (logs || []).filter((l) => l.med_id === r.id);
    const slots: string[] = [];
    if (s.type === "daily") (s.times || []).forEach((t: string) => slots.push(t));
    else {
      const last = L.filter((l) => l.taken).sort((a, b) => String(b.taken).localeCompare(String(a.taken)))[0];
      const next = last ? addDays(String(last.taken).slice(0, 10), s.every) : s.start;
      if (next && next <= date && s.time) slots.push(s.time);
    }
    for (const t of slots) {
      const at = toMin(t), sched = `${date}T${t}`;
      const done = L.some((l) => String(l.sched).slice(0, 16) === sched) || (s.type !== "daily" && L.some((l) => l.taken && String(l.taken).slice(0, 10) === date));
      if (done) continue;
      const name = `${m.name}${m.strength ? " " + m.strength : ""}`, p = who(r.household_id);
      const qty = `${m.dose} ${unit(m)}`;
      if (min >= at && min < at + WINDOW) jobs.push({ key: `${r.id}|${sched}|1`, h: r.household_id, title: `Hora do remédio${p ? " de " + p : ""}`, body: `${name}, ${qty} (${t})` });
      else if (min >= at + NUDGE && min < at + NUDGE + WINDOW) jobs.push({ key: `${r.id}|${sched}|2`, h: r.household_id, title: "Ainda não marcou", body: `${name} das ${t}. Já tomou? Marque no app.` });
    }
  }

  let sent = 0;
  for (const j of jobs) {
    const { error } = await sb.from("push_sent").insert({ key: j.key });
    if (error) continue; // já foi mandado
    for (const s of subs.filter((x) => x.household_id === j.h)) {
      try { await webpush.sendNotification(s.sub, JSON.stringify({ title: j.title, body: j.body, tag: j.key.split("|").slice(0, 2).join("|"), url: "./" })); sent++; }
      catch (e: any) { if (e?.statusCode === 404 || e?.statusCode === 410) await sb.from("push_subs").delete().eq("endpoint", s.endpoint); }
    }
  }
  await sb.from("push_sent").delete().lt("at", new Date(Date.now() - 3 * 864e5).toISOString());
  return Response.json({ sent, jobs: jobs.length });
});

/* ══════════════════════════════════════════════════════════════════════
   Άντληση επίσημων στοιχείων σύμβασης από το ΚΗΜΔΗΣ Open Data API.

   ΓΙΑΤΙ ΥΠΑΡΧΕΙ
   Τρεις ανεξάρτητοι λόγοι εμποδίζουν την απευθείας κλήση από τον browser:
     1. Η CSP της εφαρμογής επιτρέπει connect-src μόνο προς το Supabase.
     2. Το κρατικό API δεν στέλνει CORS headers.
     3. Το index.html είναι δημόσιο αρχείο· δεν αντέχει μυστικά.
   Η κλήση γίνεται εδώ, στον server. Η συνάρτηση ζει στον ίδιο host με το
   Supabase (…/functions/v1/kimdis-lookup), οπότε η CSP ΔΕΝ αλλάζει.

   Το ΚΗΜΔΗΣ Open Data είναι ανοιχτό και δωρεάν — δεν απαιτείται κλειδί.
   Τεκμηρίωση: https://cerpp.eprocurement.gov.gr/khmdhs-opendata/help

   ΤΙ ΕΠΙΣΤΡΕΦΕΙ
   Το ακατέργαστο JSON της εγγραφής (πεδίο raw), όπως ακριβώς το δίνει το
   ΚΗΜΔΗΣ. Η επιλογή πεδίων γίνεται στην εφαρμογή, ώστε τυχόν νέα πεδία του
   API να μη χάνονται σιωπηλά εδώ.
   ══════════════════════════════════════════════════════════════════════ */

const BASE = "https://cerpp.eprocurement.gov.gr/khmdhs-opendata";
const TIMEOUT_MS = 20_000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/* Ο τύπος της πράξης προκύπτει από τον ΑΔΑΜ και ορίζει το endpoint:
   ##REQ######### πρωτογενές αίτημα · ##PROC######## διακήρυξη
   ##AWRD######## κατακύρωση        · ##SYMV######## σύμβαση */
const ADAM_RE = /^(\d{2})(REQ|PROC|AWRD|SYMV)(\d{9})$/;
const PATHS: Record<string, string[]> = {
  REQ: ["request"],
  PROC: ["notice"],
  AWRD: ["award", "awardnotice", "awrd"],
  SYMV: ["contract"],
};

async function kimdhs(path: string, body: Record<string, unknown>) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE}/${path}?page=0`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(body),
      signal: ctl.signal,
    });
    const text = await r.text();
    let data: unknown = null;
    try { data = JSON.parse(text); } catch { /* μη-JSON απάντηση */ }
    return { status: r.status, data, text: data ? "" : text.slice(0, 400) };
  } finally {
    clearTimeout(timer);
  }
}

/* Το ΚΗΜΔΗΣ επιστρέφει άλλοτε πίνακα, άλλοτε {content:[…]}. */
const contentOf = (d: unknown): unknown[] => {
  if (Array.isArray(d)) return d;
  if (d && typeof d === "object" && Array.isArray((d as { content?: unknown[] }).content)) {
    return (d as { content: unknown[] }).content;
  }
  return [];
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...CORS, "Content-Type": "application/json" },
    });

  try {
    if (req.method !== "POST") return json({ error: "Δεκτό μόνο POST." }, 405);

    const { q } = await req.json();
    const query = String(q || "").trim().toUpperCase().replace(/\s+/g, "");
    if (!query) return json({ error: "Δώστε ΑΔΑΜ." }, 400);

    const m = query.match(ADAM_RE);
    if (!m) {
      return json({ error: "Μη έγκυρος ΑΔΑΜ. Αναμένεται μορφή τύπου 25SYMV017115178." }, 400);
    }

    const errors: string[] = [];
    for (const path of PATHS[m[2]]) {
      const r = await kimdhs(path, { referenceNumber: m[0] });
      const rows = contentOf(r.data);
      if (r.status === 200 && rows.length) {
        return json({
          ok: true,
          kind: m[2],
          endpoint: path,
          adam: m[0],
          attachmentUrl: `${BASE}/${path}/attachment/${m[0]}`,
          raw: rows[0],
        });
      }
      errors.push(`${path}: ${r.status}${r.text ? " " + r.text : ""}${r.status === 200 ? " (κενό)" : ""}`);
    }
    return json({
      error: `Δεν βρέθηκε εγγραφή για τον ΑΔΑΜ ${m[0]} στο ΚΗΜΔΗΣ.`,
      detail: errors.join(" · "),
    }, 404);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("kimdis-lookup:", msg);
    return json({ error: "Η επικοινωνία με το ΚΗΜΔΗΣ απέτυχε.", detail: msg }, 502);
  }
});

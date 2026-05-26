const SLACK_SIGNATURE_VERSION = "v0";
const MAX_SKEW_SECONDS = 60 * 5;

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }

    const rawBody = await request.text();
    const verified = await verifySlackRequest(request, rawBody, env.SLACK_SIGNING_SECRET);
    if (!verified) {
      return json({ error: "invalid_signature" }, 401);
    }

    const form = new URLSearchParams(rawBody);
    const userId = form.get("user_id") || "";
    const command = form.get("command") || "";
    const text = (form.get("text") || "").trim();
    const channelId = form.get("channel_id") || "";

    if (!isAllowedUser(userId, env.SLACK_ALLOWED_USER_IDS || "")) {
      return json({
        response_type: "ephemeral",
        text: `Not authorized for ${command}.`,
      });
    }

    try {
      if (command === "/do-deploy-cancel") {
        const jobId = text.split(/\s+/)[0] || "";
        if (!jobId) {
          return json({
            response_type: "ephemeral",
            text: "Usage: /do-deploy-cancel <job_id>",
          });
        }
        const cancelled = await cancelWorkflowRun(env, jobId);
        return json({
          response_type: "ephemeral",
          text: cancelled
            ? `Cancel requested for ${jobId}.`
            : `No active GitHub Actions run found for ${jobId}.`,
        });
      }

      if (command !== "/do-snapshot" && command !== "/do-restore") {
        return json({ response_type: "ephemeral", text: `Unsupported command: ${command}` });
      }

      const jobId = crypto.randomUUID();
      const operation = command === "/do-snapshot" ? "snapshot" : "restore";
      const parsed = parseArgs(text);

      const initial = await slackApi(env, "chat.postMessage", {
        channel: channelId,
        text: `on it, <@${userId}>. ${operation} job ${jobId} queued.`,
      });

      await dispatchWorkflow(env, {
        job_id: jobId,
        operation,
        slack_channel_id: channelId,
        slack_thread_ts: initial.ts,
        slack_user_id: userId,
        droplet_id: parsed.droplet_id || "",
        snapshot_name: parsed.snapshot_name || "",
        post_action: parsed.post_action || "",
        confirm_delete_name: parsed.confirm_delete_name || "",
        snapshot_id: parsed.snapshot_id || "",
        restore_region: parsed.restore_region || "",
        ssh_key_id: parsed.ssh_key_id || "",
        size_slug: parsed.size_slug || "",
        droplet_name: parsed.droplet_name || "",
        reserved_ip: parsed.reserved_ip || "",
        tags: parsed.tags || "",
        vpc_uuid: parsed.vpc_uuid || "",
        user_data_file: parsed.user_data_file || "",
        reassign_reserved_ip: parsed.reassign_reserved_ip || "false",
      });

      return json({
        response_type: "ephemeral",
        text: `Queued ${operation} job ${jobId}. Updates will appear in the thread.`,
      });
    } catch (error) {
      return json({
        response_type: "ephemeral",
        text: `Failed to start job: ${error.message}`,
      });
    }
  },
};

async function verifySlackRequest(request, rawBody, signingSecret) {
  if (!signingSecret) {
    return false;
  }

  const timestamp = request.headers.get("X-Slack-Request-Timestamp") || "";
  const signature = request.headers.get("X-Slack-Signature") || "";
  const now = Math.floor(Date.now() / 1000);

  if (!timestamp || Math.abs(now - Number(timestamp)) > MAX_SKEW_SECONDS) {
    return false;
  }

  const base = `${SLACK_SIGNATURE_VERSION}:${timestamp}:${rawBody}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(signingSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(base));
  const expected = `${SLACK_SIGNATURE_VERSION}=${hex(digest)}`;

  return constantTimeEqual(expected, signature);
}

function constantTimeEqual(a, b) {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  const max = Math.max(left.length, right.length);
  let diff = left.length ^ right.length;

  for (let i = 0; i < max; i += 1) {
    diff |= (left[i] || 0) ^ (right[i] || 0);
  }

  return diff === 0;
}

function hex(buffer) {
  return [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function isAllowedUser(userId, allowList) {
  return allowList
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean)
    .includes(userId);
}

function parseArgs(text) {
  const result = {};
  const parts = text.match(/(?:[^\s"]+|"[^"]*")+/g) || [];

  for (const part of parts) {
    const clean = part.replace(/^"|"$/g, "");
    const eq = clean.indexOf("=");
    if (eq === -1) {
      continue;
    }
    const key = clean.slice(0, eq).replace(/^--/, "").replace(/-/g, "_");
    const value = clean.slice(eq + 1);
    result[key] = value;
  }

  return result;
}

async function dispatchWorkflow(env, inputs) {
  const owner = required(env.GITHUB_OWNER, "GITHUB_OWNER");
  const repo = required(env.GITHUB_REPO, "GITHUB_REPO");
  const workflow = env.GITHUB_WORKFLOW_FILE || "snaprestore-dispatch.yml";
  const ref = env.GITHUB_REF || "next-codex";
  const url = `https://api.github.com/repos/${owner}/${repo}/actions/workflows/${workflow}/dispatches`;

  const response = await fetch(url, {
    method: "POST",
    headers: githubHeaders(env),
    body: JSON.stringify({ ref, inputs }),
  });

  if (!response.ok) {
    throw new Error(`GitHub dispatch failed: ${response.status} ${await response.text()}`);
  }
}

async function cancelWorkflowRun(env, jobId) {
  const owner = required(env.GITHUB_OWNER, "GITHUB_OWNER");
  const repo = required(env.GITHUB_REPO, "GITHUB_REPO");
  const url = `https://api.github.com/repos/${owner}/${repo}/actions/runs?branch=${encodeURIComponent(env.GITHUB_REF || "next-codex")}&per_page=50`;
  const response = await fetch(url, { headers: githubHeaders(env) });
  if (!response.ok) {
    throw new Error(`GitHub run lookup failed: ${response.status} ${await response.text()}`);
  }

  const body = await response.json();
  const run = (body.workflow_runs || []).find((candidate) => {
    const matchesJob = (candidate.name || "").includes(jobId);
    const cancellable = candidate.status === "queued" || candidate.status === "in_progress";
    return matchesJob && cancellable;
  });
  if (!run) {
    return false;
  }

  const cancel = await fetch(`https://api.github.com/repos/${owner}/${repo}/actions/runs/${run.id}/cancel`, {
    method: "POST",
    headers: githubHeaders(env),
  });

  if (!cancel.ok) {
    throw new Error(`GitHub cancel failed: ${cancel.status} ${await cancel.text()}`);
  }
  return true;
}

function githubHeaders(env) {
  return {
    "Accept": "application/vnd.github+json",
    "Authorization": `Bearer ${required(env.GITHUB_TOKEN, "GITHUB_TOKEN")}`,
    "Content-Type": "application/json",
    "User-Agent": "snaprestore-slack-worker",
    "X-GitHub-Api-Version": "2022-11-28",
  };
}

async function slackApi(env, method, payload) {
  const response = await fetch(`https://slack.com/api/${method}`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${required(env.SLACK_BOT_TOKEN, "SLACK_BOT_TOKEN")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  const body = await response.json();
  if (!body.ok) {
    throw new Error(`Slack ${method} failed: ${body.error || response.status}`);
  }
  return body;
}

function required(value, name) {
  if (!value) {
    throw new Error(`Missing ${name}`);
  }
  return value;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

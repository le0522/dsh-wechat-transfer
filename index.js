/**
 * dsh-wechat-transfer — host half.
 *
 * Exposes
 *   GET  /dsh-wechat-transfer/status      -> { script, lastResult, screenshotAge }
 *   POST /dsh-wechat-transfer/send        -> { ok, stage, ... } (runs the PowerShell engine)
 *   POST /dsh-wechat-transfer/login       -> { ok, stage, ... } (drives the login window)
 *   POST /dsh-wechat-transfer/resolve     -> { path } (deliverable card coordinates -> file)
 *   GET  /dsh-wechat-transfer/screenshot  -> latest verification screenshot (PNG)
 *
 * and registers the model facing tool `wechat_send_file`.
 *
 * The engine never presses Escape, never closes a window and never starts or stops
 * WeChat; it verifies the chat header with Windows OCR before it pastes anything.
 */
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { isAbsolute, join, resolve as resolvePath } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-wechat-transfer'
export const inject = ['webServer', 'tools', 'sessionQuery']

const ROUTE_PREFIX = '/dsh-wechat-transfer'
const SCRIPT_PATH = fileURLToPath(new URL('./scripts/wechat-send.ps1', import.meta.url))
const WORK_DIR = join(tmpdir(), 'dsh-wechat-transfer')
const SCREENSHOT_PATH = join(WORK_DIR, 'screenshot.png')
const LOG_PATH = join(WORK_DIR, 'engine.log')
const MAX_FILES = 20

const state = {
  lastResult: null,
  running: false,
  startedAt: 0,
  finishedAt: 0,
  seq: 0,
}

function ensureWorkDir() {
  try {
    mkdirSync(WORK_DIR, { recursive: true })
  } catch {
    /* ignore */
  }
}

function sameOrigin(req) {
  const origin = req.headers.origin
  if (!origin) return true
  try {
    const url = new URL(origin)
    const host = req.headers.host ?? ''
    if (url.host === host) return true
    // Reached through a tunnel / reverse proxy (mobile remote access, remote-web-ui, LAN IP
    // with a rewritten Host): accept only calls that carry our own marker header. A foreign
    // page cannot set a custom header without a CORS preflight, and this server never answers
    // one, so this stays a usable CSRF gate.
    return String(req.headers['x-dsh-wechat-transfer'] ?? '') === '1'
  } catch {
    return false
  }
}

function readJsonBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        reject(new Error('body-too-large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8').trim()
      if (!raw) return resolve({})
      try {
        resolve(JSON.parse(raw))
      } catch (error) {
        reject(error)
      }
    })
    req.on('error', reject)
  })
}

function corsHeaders(req) {
  const origin = req.headers.origin
  if (!origin) return {}
  // Remote access (phone over LAN / tunnel) can arrive from a different origin than the one in
  // Host. These routes are only meaningful with the DSH session cookie, which browsers do not
  // attach to cross-site requests, so echoing the origin is safe here.
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-credentials': 'true',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'content-type, x-dsh-wechat-transfer',
    'access-control-max-age': '600',
    vary: 'origin',
  }
}

function preflight(req, res) {
  if (req.method !== 'OPTIONS') return false
  res.writeHead(204, Object.assign({ 'cache-control': 'no-store' }, corsHeaders(req)))
  res.end()
  return true
}

function send(res, status, payload, req) {
  const body = typeof payload === 'string' ? payload : JSON.stringify(payload)
  res.writeHead(
    status,
    Object.assign(
      {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
      },
      req ? corsHeaders(req) : {},
    ),
  )
  res.end(body)
}

function normalisePaths(input) {
  const list = Array.isArray(input) ? input : typeof input === 'string' ? input.split(/\r?\n/) : []
  const paths = []
  for (const item of list) {
    if (typeof item !== 'string') continue
    const value = item.trim().replace(/^"+|"+$/g, '')
    if (!value) continue
    paths.push(value)
    if (paths.length >= MAX_FILES) break
  }
  return paths
}

function runEngine(options) {
  ensureWorkDir()
  const job = {
    paths: options.paths ?? [],
    autoSend: Boolean(options.autoSend),
    loginOnly: Boolean(options.loginOnly),
    screenshot: SCREENSHOT_PATH,
    log: LOG_PATH,
  }
  if (options.chat) job.chat = options.chat
  const jobPath = join(WORK_DIR, `job-${Date.now()}.json`)
  writeFileSync(jobPath, JSON.stringify(job, null, 2), 'utf8')

  return new Promise((resolve) => {
    const child = spawn(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT_PATH, '-Job', jobPath],
      { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] },
    )
    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => {
      try {
        child.kill()
      } catch {
        /* ignore */
      }
    }, 120_000)

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString('utf8')
    })
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString('utf8')
    })
    child.on('error', (error) => {
      clearTimeout(timer)
      resolve({ ok: false, stage: 'spawn-failed', error: String(error?.message ?? error) })
    })
    child.on('close', (code) => {
      clearTimeout(timer)
      const line = stdout
        .split(/\r?\n/)
        .map((item) => item.trim())
        .filter((item) => item.startsWith('{') && item.endsWith('}'))
        .pop()
      if (!line) {
        resolve({
          ok: false,
          stage: 'no-output',
          error: (stderr || stdout || `engine exited with ${code}`).slice(0, 2000),
        })
        return
      }
      try {
        resolve(JSON.parse(line))
      } catch (error) {
        resolve({ ok: false, stage: 'bad-output', error: String(error?.message ?? error) })
      }
    })
  })
}

function describe(result) {
  const fileNames = (result?.paths ?? []).map((item) => String(item).split(/[\\/]/).pop())
  const files = fileNames.join('、') || '(没有文件)'
  const chat = result?.chat ?? '文件传输助手'
  switch (result?.stage) {
    case 'sent':
      return `已发送 ${files} 到「${chat}」并已确认出现在聊天里。`
    case 'staged':
      return `已把 ${files} 放进「${chat}」的输入框（没有自动发送），请你在微信里确认后点发送。`
    case 'chat-not-open':
      return `没有发送：当前微信打开的聊天不是「${chat}」。请在微信里点开该聊天，然后重试。`
    case 'chat-ambiguous':
      return `没有发送：会话列表里有多个叫「${chat}」的聊天，OCR 分不出是哪一个。请你自己在微信里点开正确的那一个，再重试。`
    case 'logged-in':
      return '微信已登录，可以发送文件了。'
    case 'login-required':
      return '没能自动登录：微信登录窗口没有出现「进入微信」按钮，请手动点一下或扫码登录。'
    case 'login-qr':
      return '微信要求扫码登录：请在微信登录窗口用手机扫码，然后再试一次。'
    case 'wechat-missing':
      return '没有发送：找不到微信程序（Weixin.exe），请确认已安装微信。'
    case 'wechat-not-starting':
      return '没有发送：微信启动了但一直没有出现窗口，请手动打开微信后重试。'
    case 'not-logged-in':
      return '没有发送：微信还停在登录界面，请先登录。'
    case 'input-blocked':
      return '没有发送：微信这次完全没响应鼠标操作（📁 按钮和粘贴都没反应）。请在托盘右键退出微信后重新打开并登录，再试一次。'
    case 'paste-not-verified':
      return `没有成功粘贴：${files} 没有出现在「${chat}」的输入框里（已截图）。`
    case 'send-not-verified':
      return `文件已放进「${chat}」的输入框，但没能确认发送（已截图）。`
    case 'ocr-unavailable':
      return '没有发送：系统 OCR 不可用，无法先核对聊天窗口。'
    case 'no-output':
    case 'spawn-failed':
    case 'bad-output':
      return `没有发送：驱动脚本执行失败（${result?.error ?? '未知错误'}）。`
    default:
      return `没有发送：${result?.error ?? '未知错误'}`
  }
}

export function apply(ctx) {
  ensureWorkDir()

  const log = (...args) => {
    try {
      ctx.logger?.info?.('[dsh-wechat-transfer]', ...args)
    } catch {
      /* ignore */
    }
  }

  const handleSend = async (payload) => {
    if (state.running) {
      return { ok: false, stage: 'busy', error: 'another transfer is still running' }
    }
    const paths = normalisePaths(payload?.paths)
    if (paths.length === 0) {
      return { ok: false, stage: 'no-files', error: 'no file paths were given' }
    }
    const missing = paths.filter((item) => !existsSync(item))
    if (missing.length > 0) {
      return { ok: false, stage: 'no-files', error: `file not found: ${missing.join(', ')}` }
    }
    if (!existsSync(SCRIPT_PATH)) {
      return { ok: false, stage: 'engine-missing', error: `engine script missing: ${SCRIPT_PATH}` }
    }
    state.running = true
    state.startedAt = Date.now()
    try {
      const result = await runEngine({
        paths,
        chat: typeof payload?.chat === 'string' ? payload.chat : undefined,
        autoSend: payload?.autoSend === true,
      })
      state.lastResult = { ...result, at: Date.now(), seq: ++state.seq }
      state.finishedAt = Date.now()
      log('send finished', result.stage, result.ok)
      return result
    } finally {
      state.running = false
    }
  }

  const handleLogin = async () => {
    if (state.running) {
      return { ok: false, stage: 'busy', error: 'another transfer is still running' }
    }
    if (!existsSync(SCRIPT_PATH)) {
      return { ok: false, stage: 'engine-missing', error: `engine script missing: ${SCRIPT_PATH}` }
    }
    state.running = true
    state.startedAt = Date.now()
    try {
      const result = await runEngine({ paths: [], loginOnly: true })
      state.lastResult = { ...result, at: Date.now(), seq: ++state.seq }
      state.finishedAt = Date.now()
      log('login finished', result.stage)
      return result
    } finally {
      state.running = false
    }
  }

  /**
   * Turn deliverable-card coordinates (`/api/present.open?sessionId=&seq=&index=`) into the
   * absolute Host path the engine needs. Mirrors what the deliverables host half does.
   */
  async function resolvePresentedFile(query) {
    const sessionId = query.get('sessionId')
    const rawSeq = query.get('seq')
    const rawIndex = query.get('index')
    const seq = Number(rawSeq)
    const index = Number(rawIndex)
    if (!sessionId || rawSeq === null || rawIndex === null || !Number.isSafeInteger(seq) || !Number.isSafeInteger(index)) {
      return { ok: false, stage: 'bad-coordinates', error: 'sessionId/seq/index are required' }
    }
    const read = await ctx.sessionQuery.readEvent({ sessionId, seq, before: 0, after: 0 })
    const target = read?.target ?? read?.event
    const session = read?.session
    if (!target || target.type !== 'deliverables/presented') {
      return { ok: false, stage: 'not-presented', error: `event ${seq} is not a deliverable declaration` }
    }
    const files = Array.isArray(target.data?.files) ? target.data.files : []
    const file = files[index]
    if (!file || typeof file.path !== 'string' || file.path.length === 0) {
      return { ok: false, stage: 'no-such-file', error: `the declaration has no file at index ${index}` }
    }
    const cwd = session?.cwd
    let path = file.path
    if (!isAbsolute(path)) {
      if (!cwd) return { ok: false, stage: 'no-cwd', error: 'the session recorded no working directory' }
      path = resolvePath(cwd, path)
    }
    return { ok: true, stage: 'resolved', path, description: file.description ?? null }
  }

  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: `${ROUTE_PREFIX}/login`,
        handler: async (req, res) => {
          if (preflight(req, res)) return
          if (req.method !== 'POST') return send(res, 405, { error: 'method-not-allowed' }, req)
          if (!sameOrigin(req)) return send(res, 403, { error: 'origin-rejected' }, req)
          try {
            const result = await handleLogin()
            send(res, 200, result)
          } catch (error) {
            send(res, 400, { ok: false, stage: 'error', error: String(error?.message ?? error) })
          }
        },
      }),
    'dsh-wechat-transfer/login',
  )

  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: `${ROUTE_PREFIX}/resolve`,
        handler: async (req, res) => {
          if (preflight(req, res)) return
          if (req.method !== 'POST') return send(res, 405, { error: 'method-not-allowed' }, req)
          if (!sameOrigin(req)) return send(res, 403, { error: 'origin-rejected' }, req)
          const type = String(req.headers['content-type'] ?? '')
          if (!type.includes('application/json')) return send(res, 415, { error: 'json-required' })
          try {
            const payload = await readJsonBody(req)
            const query = new URLSearchParams()
            for (const key of ['sessionId', 'seq', 'index']) {
              if (payload?.[key] !== undefined && payload?.[key] !== null) query.set(key, String(payload[key]))
            }
            const result = await resolvePresentedFile(query)
            send(res, result.ok ? 200 : 404, result)
          } catch (error) {
            send(res, 400, { ok: false, stage: 'error', error: String(error?.message ?? error) })
          }
        },
      }),
    'dsh-wechat-transfer/resolve',
  )

  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: `${ROUTE_PREFIX}/status`,
        handler: (req, res) => {
          if (preflight(req, res)) return
          if (req.method !== 'GET') return send(res, 405, { error: 'method-not-allowed' }, req)
          if (!sameOrigin(req)) return send(res, 403, { error: 'origin-rejected' }, req)
          let screenshotAge = null
          try {
            screenshotAge = Date.now() - statSync(SCREENSHOT_PATH).mtimeMs
          } catch {
            screenshotAge = null
          }
          send(res, 200, {
            engine: existsSync(SCRIPT_PATH),
            running: state.running,
            startedAt: state.running ? state.startedAt : null,
            finishedAt: state.finishedAt,
            seq: state.seq,
            now: Date.now(),
            lastResult: state.lastResult,
            screenshotAge,
          })
        },
      }),
    'dsh-wechat-transfer/status',
  )

  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: `${ROUTE_PREFIX}/send`,
        handler: async (req, res) => {
          if (preflight(req, res)) return
          if (req.method !== 'POST') return send(res, 405, { error: 'method-not-allowed' }, req)
          if (!sameOrigin(req)) return send(res, 403, { error: 'origin-rejected' }, req)
          const type = String(req.headers['content-type'] ?? '')
          if (!type.includes('application/json')) return send(res, 415, { error: 'json-required' })
          try {
            const payload = await readJsonBody(req)
            const result = await handleSend(payload)
            send(res, 200, result)
          } catch (error) {
            send(res, 400, { ok: false, stage: 'error', error: String(error?.message ?? error) })
          }
        },
      }),
    'dsh-wechat-transfer/send',
  )

  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: `${ROUTE_PREFIX}/screenshot`,
        handler: (req, res) => {
          if (preflight(req, res)) return
          if (req.method !== 'GET') return send(res, 405, { error: 'method-not-allowed' }, req)
          if (!existsSync(SCREENSHOT_PATH)) {
            res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' })
            res.end('no-screenshot')
            return
          }
          try {
            const image = readFileSync(SCREENSHOT_PATH)
            res.writeHead(200, {
              'content-type': 'image/png',
              'cache-control': 'no-store',
              'content-length': image.length,
            })
            res.end(image)
          } catch (error) {
            send(res, 500, { error: String(error?.message ?? error) })
          }
        },
      }),
    'dsh-wechat-transfer/screenshot',
  )

  try {
    ctx.tools.register({
      name: 'wechat_send_file',
      description:
        'Send local files to a WeChat chat through the WeChat 4.x desktop app (default target: 文件传输助手). The open chat is verified with Windows OCR before anything is pasted, so it refuses to act when the wrong chat is open. With autoSend=false the files are only staged in the composer for the user to review and send.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          paths: {
            type: 'array',
            description: 'Absolute paths of the files to send.',
            items: { type: 'string' },
          },
          chat: {
            type: 'string',
            description: 'Target chat name. Defaults to 文件传输助手.',
          },
          autoSend: {
            type: 'boolean',
            description: 'Click the send button after the files are staged. Defaults to false.',
          },
        },
        required: ['paths'],
      },
      output: {
        schema: { type: 'string' },
        render: (_args, value) => [{ type: 'text', text: String(value) }],
      },
      async execute(args) {
        const result = await handleSend({
          paths: args?.paths,
          chat: args?.chat,
          autoSend: args?.autoSend === true,
        })
        const detail = result?.ok ? '' : `\n阶段: ${result?.stage}`
        return `${describe(result)}${detail}`
      },
    })
  } catch (error) {
    log('failed to register tool', String(error?.message ?? error))
  }
}

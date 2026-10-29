/**
 * dsh-wechat-transfer — web client bundle.
 *
 * Registers the left sidebar entry (`sidebar.panellist`) plus its keyed panel
 * (`main`). The panel drives the host route /dsh-wechat-transfer/send and shows the
 * verification screenshot that the PowerShell engine takes before/after pasting.
 */
window.__ModuleLoader__.load({
  id: 'dsh-wechat-transfer',
  factory(require) {
    const React = require('react')
    const h = React.createElement

    const SIDEBAR_PANEL_ID = 'dsh-wechat-transfer'
    const API = '/dsh-wechat-transfer'

    // A phone or another computer reaches this app through the remote gateway: the harness Host
    // fence answers 403 for any non-loopback authority that is not under /remote, so the same
    // routes must be requested as /remote/dsh-wechat-transfer/... there. The first 403/404 flips
    // the client to that prefix for the rest of the session.
    let remotePrefix = null // null = undecided, '' = local, '/remote' = through the gateway
    function apiBase() {
      return `${remotePrefix ?? ''}${API}`
    }

    const styles = {
      root: {
        display: 'flex',
        flexDirection: 'column',
        gap: '12px',
        height: '100%',
        padding: '14px',
        boxSizing: 'border-box',
        overflowY: 'auto',
        fontSize: '13px',
        lineHeight: 1.5,
      },
      header: { display: 'flex', flexDirection: 'column', gap: '2px' },
      title: { fontSize: '15px', fontWeight: 600 },
      subtitle: { opacity: 0.65, fontSize: '12px' },
      label: { fontSize: '12px', fontWeight: 600, opacity: 0.8 },
      textarea: {
        width: '100%',
        minHeight: '84px',
        boxSizing: 'border-box',
        padding: '8px',
        borderRadius: '8px',
        border: '1px solid rgba(128,128,128,0.35)',
        background: 'transparent',
        color: 'inherit',
        fontFamily: 'inherit',
        fontSize: '12px',
        resize: 'vertical',
      },
      input: {
        width: '100%',
        boxSizing: 'border-box',
        padding: '7px 8px',
        borderRadius: '8px',
        border: '1px solid rgba(128,128,128,0.35)',
        background: 'transparent',
        color: 'inherit',
        fontFamily: 'inherit',
        fontSize: '12px',
      },
      row: { display: 'flex', gap: '8px', alignItems: 'center' },
      toggle: { display: 'flex', gap: '6px', alignItems: 'center', fontSize: '12px' },
      button: {
        padding: '7px 14px',
        borderRadius: '8px',
        border: 'none',
        cursor: 'pointer',
        fontSize: '12px',
        fontWeight: 600,
        background: '#12b886',
        color: '#fff',
      },
      buttonGhost: {
        padding: '7px 14px',
        borderRadius: '8px',
        cursor: 'pointer',
        fontSize: '12px',
        border: '1px solid rgba(128,128,128,0.4)',
        background: 'transparent',
        color: 'inherit',
      },
      status: { padding: '8px 10px', borderRadius: '8px', background: 'rgba(128,128,128,0.12)', fontSize: '12px' },
      log: {
        fontFamily: 'ui-monospace, Consolas, monospace',
        fontSize: '11px',
        whiteSpace: 'pre-wrap',
        maxHeight: '140px',
        overflowY: 'auto',
        opacity: 0.75,
      },
      shot: { width: '100%', borderRadius: '8px', border: '1px solid rgba(128,128,128,0.3)' },
      cardAction: {
        padding: '3px 9px',
        borderRadius: '999px',
        border: '1px solid rgba(128,128,128,0.4)',
        background: 'transparent',
        color: 'inherit',
        cursor: 'pointer',
        fontSize: '11px',
        fontWeight: 600,
        lineHeight: 1.6,
        whiteSpace: 'nowrap',
      },
      cardActionDone: { borderColor: '#12b886', color: '#0ea371' },
      cardActionFail: { borderColor: '#f59f00', color: '#d9480f' },
    }

    async function callApi(path, options) {
      const opts = Object.assign({ credentials: 'same-origin', cache: 'no-store' }, options)
      const headers = Object.assign({ 'x-dsh-wechat-transfer': '1' }, opts.headers ?? {})
      opts.headers = headers
      // mobile Safari / proxy caches answer GETs from cache; a unique query defeats that
      const suffix = opts.method && opts.method !== 'GET' ? '' : `${path.includes('?') ? '&' : '?'}_=${Date.now()}`
      const target = path + suffix
      const run = () => fetch(apiBase() + target, opts)
      let response
      try {
        response = await run()
      } catch (error) {
        return { ok: false, stage: 'error', error: String(error?.message ?? error) }
      }
      if ((response.status === 403 || response.status === 404) && remotePrefix === null) {
        // reached from another device: retry through the remote gateway once
        remotePrefix = '/remote'
        response = await run()
        if (response.status === 403 || response.status === 404) {
          // the gateway did not take it either - do not stay stuck on the wrong prefix
          remotePrefix = ''
          const detail = await response.text().catch(() => '')
          return {
            ok: false,
            stage: 'unreachable',
            error: `远程访问下插件路由不可达（HTTP ${response.status}）${detail ? `: ${detail.slice(0, 120)}` : ''}`,
          }
        }
      } else if (response.ok && remotePrefix === null) {
        remotePrefix = ''
      }
      const text = await response.text()
      try {
        return JSON.parse(text)
      } catch {
        return { ok: false, stage: 'bad-response', error: text.slice(0, 400) }
      }
    }

    const STAGE_TEXT = {
      sent: '已发送，已确认出现在聊天里',
      staged: '已放入输入框，等待你点发送',
      'chat-not-open': '当前聊天不是目标聊天，已中止（未粘贴）',
      'logged-in': '微信已登录',
      'login-required': '没能自动登录，请手动点「进入微信」',
      'login-qr': '需要手机扫码登录',
      'not-logged-in': '微信还没登录',
      'input-blocked': '微信没响应鼠标操作，请退出微信（托盘右键退出）后重新打开',
      'paste-not-verified': '文件没有出现在输入框',
      'send-not-verified': '已放入输入框，但没能确认发送',
      'ocr-unavailable': '系统 OCR 不可用，已中止',
      'no-files': '没有可发送的文件（或路径不存在）',
      'engine-missing': '找不到引擎脚本',
      busy: '上一次传输还在进行',
      unreachable: '手机上够不到电脑里的插件服务（远程网关没转发这条路由）',
      error: '出错',
    }

    /** Compact per-file action on a deliverable card: send that one file to WeChat. */
    function DeliverableSendButton(props) {
      const [phase, setPhase] = React.useState('idle')
      const [message, setMessage] = React.useState('')
      const actionUrl = typeof props?.actionUrl === 'string' ? props.actionUrl : ''

      const send = React.useCallback(
        async (event) => {
          event.preventDefault()
          event.stopPropagation()
          if (phase === 'busy') return
          setPhase('busy')
          setMessage('')
          try {
            const query = actionUrl.includes('?') ? actionUrl.slice(actionUrl.indexOf('?') + 1) : ''
            const params = new URLSearchParams(query)
            const resolved = await callApi('/resolve', {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({
                sessionId: params.get('sessionId'),
                seq: params.get('seq'),
                index: params.get('index'),
              }),
            })
            if (!resolved?.ok || !resolved.path) throw new Error(resolved?.error ?? '解析文件路径失败')
            const result = await callApi('/send', {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ paths: [resolved.path], autoSend: true }),
            })
            if (!result?.ok) throw new Error(result?.error ?? STAGE_TEXT[result?.stage] ?? result?.stage ?? '发送失败')
            setPhase('done')
            setMessage(`已发送到微信：${String(resolved.path).split(/[\\/]/).pop()}`)
            setTimeout(() => setPhase('idle'), 2600)
          } catch (error) {
            setPhase('fail')
            setMessage(String(error?.message ?? error))
            setTimeout(() => setPhase('idle'), 7000)
          }
        },
        [actionUrl, phase],
      )

      const label = phase === 'busy' ? '发送中…' : phase === 'done' ? '✓ 已发' : phase === 'fail' ? '⚠ 失败' : '发微信'
      return h(
        'button',
        {
          type: 'button',
          title: message || '把这个文件发送到微信「文件传输助手」',
          'aria-label': '发送到微信',
          onClick: send,
          disabled: phase === 'busy',
          style: Object.assign({}, styles.cardAction, phase === 'done' ? styles.cardActionDone : {}, phase === 'fail' ? styles.cardActionFail : {}),
        },
        label,
      )
    }

    function Panel() {
      const [paths, setPaths] = React.useState('')
      const [chat, setChat] = React.useState('文件传输助手')
      const [autoSend, setAutoSend] = React.useState(false)
      const [busy, setBusy] = React.useState(false)
      const [result, setResult] = React.useState(null)
      const [shotKey, setShotKey] = React.useState(0)

      const run = React.useCallback(async () => {
        setBusy(true)
        try {
          const payload = {
            paths: paths.split(/\r?\n/).map((item) => item.trim()).filter(Boolean),
            chat: chat.trim() || '文件传输助手',
            autoSend,
          }
          if (payload.paths.length === 0) {
            setResult({ ok: false, stage: 'no-files', error: '请先填写文件路径' })
            return
          }
          const data = await callApi('/send', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(payload),
          })
          setResult(data)
          setShotKey(Date.now())
        } catch (error) {
          setResult({ ok: false, stage: 'error', error: String(error?.message ?? error) })
        } finally {
          setBusy(false)
        }
      }, [paths, chat, autoSend])

      // Poll while a run is in flight so the panel always shows the live result, not the one
      // that happened to be cached when the panel was opened.
      React.useEffect(() => {
        if (!busy) return undefined
        let stopped = false
        const timer = setInterval(async () => {
          const data = await callApi('/status')
          if (stopped || !data) return
          if (data.lastResult) setResult(data.lastResult)
          if (!data.running) setShotKey(Date.now())
        }, 1500)
        return () => {
          stopped = true
          clearInterval(timer)
        }
      }, [busy])

      const stamp = (value) => {
        if (!value) return ''
        try {
          return new Date(value).toLocaleTimeString()
        } catch {
          return ''
        }
      }

      const statusLine = result
        ? `${result.ok ? '✅' : '⚠️'} ${STAGE_TEXT[result.stage] ?? result.stage}${result.error ? ` — ${result.error}` : ''}${result.at ? `（${stamp(result.at)}）` : ''}`
        : '就绪：请先在微信里打开目标聊天（默认「文件传输助手」）'

      return h(
        'div',
        { style: styles.root },
        h(
          'div',
          { style: styles.header },
          h('div', { style: styles.title }, '微信传输助手'),
          h('div', { style: styles.subtitle }, '安全模式：先核对聊天窗口，再粘贴文件'),
        ),
        h(
          'div',
          null,
          h('div', { style: styles.label }, '要发送的文件（每行一个完整路径）'),
          h('textarea', {
            style: styles.textarea,
            spellCheck: false,
            placeholder: 'C:\\Users\\me\\Documents\\报告.pdf',
            value: paths,
            onChange: (event) => setPaths(event.target.value),
          }),
        ),
        h(
          'div',
          null,
          h('div', { style: styles.label }, '目标聊天'),
          h('input', {
            style: styles.input,
            value: chat,
            spellCheck: false,
            onChange: (event) => setChat(event.target.value),
          }),
        ),
        h(
          'label',
          { style: styles.toggle },
          h('input', {
            type: 'checkbox',
            checked: autoSend,
            onChange: (event) => setAutoSend(event.target.checked),
          }),
          h('span', null, '粘贴后自动点击发送'),
        ),
        h('div', { style: styles.subtitle }, '关闭时只把文件放进输入框，由你确认后发送。'),
        h(
          'div',
          { style: styles.row },
          h(
            'button',
            { style: Object.assign({}, styles.button, busy ? { opacity: 0.6, cursor: 'wait' } : {}), onClick: run, disabled: busy },
            busy ? '正在处理…' : '发送',
          ),
          h(
            'button',
            {
              style: styles.buttonGhost,
              disabled: busy,
              onClick: async () => {
                setBusy(true)
                try {
                  const data = await callApi('/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' })
                  setResult(data)
                  setShotKey(Date.now())
                } catch (error) {
                  setResult({ ok: false, stage: 'error', error: String(error?.message ?? error) })
                } finally {
                  setBusy(false)
                }
              },
            },
            '登录微信',
          ),
          h(
            'button',
            {
              style: styles.buttonGhost,
              disabled: busy,
              onClick: async () => {
                const data = await callApi('/status')
                setResult(data?.lastResult ?? { ok: false, stage: 'error', error: '还没有执行记录' })
                setShotKey(Date.now())
              },
            },
            '刷新状态',
          ),
        ),
        h('div', { style: styles.status }, statusLine),
        result?.log?.length
          ? h('div', { style: styles.log }, result.log.slice(-24).join('\n'))
          : null,
        h('img', {
          key: shotKey,
          style: styles.shot,
          alt: '微信窗口截图',
          src: `${apiBase()}/screenshot?t=${shotKey}`,
          onError: (event) => {
            event.currentTarget.style.display = 'none'
          },
        }),
        h('div', { style: styles.subtitle }, '模型也可以直接调用工具 wechat_send_file 发送文件。'),
      )
    }

    function Icon(owner = {}) {
      const size = owner.size ?? 16
      return h(
        'svg',
        {
          width: size,
          height: size,
          viewBox: '0 0 24 24',
          fill: 'none',
          stroke: 'currentColor',
          strokeWidth: 1.7,
          strokeLinecap: 'round',
          strokeLinejoin: 'round',
          'aria-hidden': true,
        },
        h('path', { d: 'M20.5 11.2c0 3.6-3.6 6.5-8 6.5-.9 0-1.8-.1-2.6-.3l-3.4 1.6.9-2.7C5.6 15.2 4.5 13.3 4.5 11.2c0-3.6 3.6-6.5 8-6.5s8 2.9 8 6.5Z' }),
        h('path', { d: 'M9.3 10.9h.01M13.6 10.9h.01M16.9 16.2l3 1.4-.8-2.4' }),
      )
    }

    let layout = null

    return {
      inject: ['slots'],
      apply(ctx) {
        ctx.inject(['layout'], (scoped) => {
          layout = scoped.layout
        })

        ctx.slots.inject('sidebar.panellist', () => {
          const disposers = []
          disposers.push(
            ctx.slots.register({ name: 'main', key: SIDEBAR_PANEL_ID }, () => h(Panel, null)),
          )
          disposers.push(
            ctx.slots.register(
              { name: 'sidebar.panellist', id: SIDEBAR_PANEL_ID, order: 12, label: '微信传输' },
              (owner) => h(Icon, owner ?? {}),
            ),
          )
          return () => {
            for (const dispose of disposers) {
              try {
                dispose()
              } catch {
                /* ignore */
              }
            }
            try {
              if (layout?.panelInfo?.getSnapshot?.().activePanelId === SIDEBAR_PANEL_ID) {
                layout.selectPanel(null)
              }
            } catch {
              /* ignore */
            }
          }
        })

        // One-click transfer from every deliverable card (`present` output) in the chat.
        try {
          ctx.slots.inject('deliverables.file.actions', () => {
            try {
              return ctx.slots.register(
                { name: 'deliverables.file.actions', id: SIDEBAR_PANEL_ID, order: 30 },
                (owner) => h(DeliverableSendButton, owner ?? {}),
              )
            } catch (error) {
              return () => {}
            }
          })
        } catch {
          /* the deliverables package is not mounted in this composition */
        }
      },
    }
  },
})

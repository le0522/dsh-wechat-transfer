# 把 dsh-wechat-transfer 收录进插件市场：一步一步

先说清机制，避免白跑：

- **没有「官方审核上架」这条路。** 生态里是几个社区目录站各扫各的。
- 三件事互相独立，做完哪件就有哪件的效果：

| 站点 / 渠道 | 怎么进 | 门槛 | 速度 |
|---|---|---|---|
| dshfind 等自动聚合站 | 给 GitHub 仓库打 `dsh-plugin` topic | 只要仓库公开 | 下一次抓取（约一天） |
| 1024Store（deepseek1024.com） | 向 `imsai-sh/awesome-deepseek-harness-plugins` 提 PR，新增 1 个 JSON | 仓库里有非空 `dsh.bundle.patch` | CI 过了自动合并 |
| awesome-dsh-plugin | 向 `awesome-dsh-plugin/awesome-dsh-plugin` 提 PR，新增 1 个 YAML + 重新生成的 README | **仓库创建满 1 天且提交数 ≥ 10** | 人工审核 |

共同前提只有一条：**插件得在一个公开的 GitHub 仓库里。** 现在它只在你本地。

---

## 第 0 步：本地已经替你做好了

在 `<插件目录>` 里已经完成：

- `package.json`
  - 去掉 `"private": true`（否则 `npm publish` 会被拒）
  - 加 `"license": "MIT"`、`"os": ["win32"]`、`"keywords": ["dsh-plugin", "deepseek-harness", "dsh", "wechat", "weixin", "file-transfer", "windows"]`
  - `dsh.bundle.patch` → `./cordis.patch.yml` 保留（这是能被 `dsh plugin add` 安装的凭证，CI 只认它）
  - `dsh.client.platform` → `web` 保留（侧边栏面板靠它加载）
  - `files` 补上 `LICENSE`
- `LICENSE`（MIT）
- `.gitignore`、`.gitattributes`
- `docs/listing/1024store-entry.json`、`docs/listing/awesome-dsh-plugin-entry.yml`（两个提交模板，把 `<GITHUB_OWNER>` 换成你的用户名即可）
- `docs/screenshots/` 三张实拍图
- `git init` + 第一个提交

确认一下：

```powershell
cd <插件目录>
git log --oneline
git rev-list --count HEAD
node --check index.js
node --check client.js
```

---

## 第 1 步：建公开仓库并推上去

在 GitHub 网页上 **New repository**：

- 名字：`dsh-wechat-transfer`
- 可见性：**Public**（私有仓库不会被任何目录站扫到）
- **不要**勾选 Add README / .gitignore / license（本地已经有了）

然后本地：

```powershell
cd <插件目录>
git branch -M main
git remote add origin https://github.com/<你的用户名>/dsh-wechat-transfer.git
git push -u origin main
```

推完用无痕窗口打开 `https://github.com/<你的用户名>/dsh-wechat-transfer` 确认：

- 能看到 `package.json`、`index.js`、`client.js`、`cordis.patch.yml`、`scripts/wechat-send.ps1`
- `package.json` 里 `dsh.bundle.patch` 是 `./cordis.patch.yml`
- 仓库根目录没有把 `node_modules` 之类垃圾提交上去

> 如果 HTTPS 推送要账号密码，用 GitHub 的 Personal Access Token 当密码，或者先 `git config --global credential.helper manager`。

---

## 第 2 步：打 topic（当天就能进自动聚合站）

仓库页 → 右侧齿轮 **Topics** → 加三个：

```
dsh-plugin
deepseek-harness
dsh
```

`dsh-plugin` 是必须的那个。加完之后，dshfind 这类「按 topic 聚合」的站点会在下次刷新时自动收录，你什么都不用提。

---

## 第 3 步：PR 到 1024Store（最快拿到「正式收录」）

这是目前唯一「CI 过了自动合并」的渠道，值得先做。

1. 打开 `https://github.com/imsai-sh/awesome-deepseek-harness-plugins` → **Fork**
2. 在你 fork 的仓库里新建文件：

   ```
   catalog/plugins/<你的用户名小写>--dsh-wechat-transfer.json
   ```

   例如用户名是 `lele`，文件名就是 `lele--dsh-wechat-transfer.json`（规则：`owner/repo` 每段小写、非字母数字连续段换成 `-`，两段之间用 `--`）。

3. 内容照抄 `docs/listing/1024store-entry.json`，只改三处：

   - `id` → `<你的用户名>/dsh-wechat-transfer`
   - `repository` → `https://github.com/<你的用户名>/dsh-wechat-transfer`
   - `added` → 今天日期，`2026-10-29` 这种格式

4. 提 PR，标题写：

   ```
   Add <你的用户名>/dsh-wechat-transfer
   ```

   **diff 里只能有这一个文件。** 不要顺手改 README、workflow、脚本——那些是 bot 生成的，动了一律被拒。

5. CI 会拉你仓库的 `package.json` 检查 `dsh.bundle.patch` 是否非空、patch 文件是否存在，过了就自动 squash merge。

   - 合了 = 你的插件出现在 deepseek1024.com 的目录里
   - 没合：看 CI 日志，九成是 `dsh.bundle.patch` 或文件名规则不对

---

## 第 4 步：PR 到 awesome-dsh-plugin（权重最高，但要等门槛）

门槛是硬性的：**仓库创建满 1 天，且提交数 ≥ 10**。别为了凑数造空提交，维护者会读仓库，一看就知道。

自查：

```powershell
git rev-list --count HEAD          # 要 ≥ 10
```

够数之后再提：

1. Fork `https://github.com/awesome-dsh-plugin/awesome-dsh-plugin`
2. 新建 `data/plugins/<你的用户名>__dsh-wechat-transfer.yml`，内容照抄 `docs/listing/awesome-dsh-plugin-entry.yml`（注意是双下划线 `__`，owner 大小写保持原样）
3. 本地按它对 README 的要求重新生成（**不要手改 README**）：

   ```powershell
   git clone https://github.com/<你的用户名>/awesome-dsh-plugin.git
   cd awesome-dsh-plugin
   npm ci
   node scripts/generate-readme.mjs
   git add data/plugins/<你的用户名>__dsh-wechat-transfer.yml README.md README.zh.md
   ```

   （脚本具体输出哪几个 README，以仓库当时的 `scripts/generate-readme.mjs` 为准，别猜。）

4. 提 PR，标题：

   ```
   Add <你的用户名>/dsh-wechat-transfer
   ```

5. 描述里写清这几件事，能显著提高过审率：

   - 只在 Windows 上可用，依赖微信 4.x 桌面端
   - 侧边栏面板 + `wechat_send_file` 工具 + 产物卡片按钮，**三处入口**
   - 附加文件前会用 Windows OCR 校验当前聊天是不是目标聊天，不是就拒绝
   - 默认只把文件放进输入框，`autoSend` 才点发送
   - 微信没开时能自己拉起并点「进入微信」，只出现二维码就报错不猜

   **描述里的每句话都要能在代码里对上。** 夸大是主要退回原因。

---

## 第 5 步（可选，但建议）：发到 npm

npm 包能免掉 `dsh plugin add` 的构建授权环节，安装体验最好。先查名字是否被占：

```powershell
npm view dsh-wechat-transfer version
```

- 报 404 → 名字可用
- 有版本号 → 改 `package.json` 的 `name`（如 `@<你的用户名>/dsh-wechat-transfer`），并同步改 `docs/listing/*` 里的描述

发布：

```powershell
cd <插件目录>
npm login
npm publish --access public
```

发完验证安装：

```powershell
dsh plugin --profile desktop add dsh-wechat-transfer
dsh plugin --profile desktop add dsh-wechat-transfer
```

装完重启 DSH，看左侧栏有没有「微信传输」。

---

## 第 6 步：怎么确认「收录成功」

| 检查 | 期望 |
|---|---|
| `https://github.com/<你>/dsh-wechat-transfer` 的 Topics | 有 `dsh-plugin` |
| 1024Store 目录仓里的文件 | 你的 JSON 已 merge |
| `https://awesome-dsh-plugin.com/plugins.json` | 搜得到 `dsh-wechat-transfer` |
| 别人在自己机器上 | `dsh plugin --profile web add <spec>` 能装上、侧边栏出现入口 |

想立刻看本地是否被市场收录（不用等站点抓取）：装一个市场插件（你已经装了 `dshmarket`），在 Settings → 插件市场里搜 `wechat`。

---

## 第 7 步：收录之后要维护的

- **描述与代码同步**：以后改了功能（比如加了新入口），PR 描述/yml 里的说法要跟着改
- **仓库保持活跃**：长期停更的条目会被移除
- **Windows 边界说清楚**：这是 Windows-only 插件，描述里不要暗示跨平台
- **微信版本漂移**：截图坐标是相对窗口比例的，微信改版后要回归测试；README 里那句「微信 4.1.15.13 拒绝 CF_HDROP 粘贴」也要随版本更新

---

## 常见被拒原因（对照自查）

1. 只有 `dsh.client`，没有 `dsh.bundle.patch` → **装不上，直接拒**
2. 仓库私有 / 没有 `dsh-plugin` topic → 扫不到
3. PR 里动了 `catalog/plugins/` 之外的文件 → 一律拒
4. 提交数凑出来的 → 人工审核会看出来
5. yml 文件名不是 `<owner>__<repo>.yml` → CI 找不到
6. 手改 README 而不是跑生成脚本 → diff 冲突
7. 描述夸大（工具数量、平台范围） → 维护者读代码后打回
8. profile 的 `cordis.patch.yml` 里又插了一条同名 `id` → `duplicate loader entry id`，DSH 启动崩溃

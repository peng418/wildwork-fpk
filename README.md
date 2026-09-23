# Wild Work — 飞牛 fnOS FPK（端口 5013 · 页内弹窗 · IPv4/IPv6 双栈）

## 这是什么

把上游 [rockswang/wild-work](https://github.com/rockswang/wild-work)（v2.4.1，多 IDE 账号池 → OpenAI 兼容 API）
封装成**飞牛 fnOS 原生 FPK 应用**。安装后是系统里的一个普通应用，**不依赖 Docker**。

| 项目 | 值 |
|---|---|
| 包名 | `wildwork-2.4.1.fpk` |
| 应用 ID | `wildwork` |
| 版本 | 2.4.1（上游二进制 sha256 `37f976c4d48cecbc80c381cd3cdcd5d01296969d7b605869fbf2b17bf3f75c29`） |
| 服务端口 | **5013** |
| 监听地址 | `0.0.0.0:5013` = **IPv4 + IPv6 双栈** |
| 桌面入口 | 飞牛桌面窗口内**页内弹窗**（统一网关 `/app/wildwork`），**不跳转页面、不开新标签** |
| 数据目录 | `/vol6/@appdata/wildwork`（状态/日志）、`/vol6/@apphome/wildwork`（HOME） |
| API 地址 | `http://<NAS-IP>:5013/v1` 或 `http://[<NAS-IPv6>]:5013/v1` |

## 安装

1. 飞牛桌面 → **应用中心 → 手动安装 / 本地安装** → 选 `wildwork-2.4.1.fpk`
2. 安装向导会说明用法，直接下一步到底
3. 安装完成后桌面出现两个图标：
   - **Wild Work** —— 主入口，点开是桌面内弹窗（走统一网关）
   - **Wild Work 登录补投** —— 添加账号时粘贴 `127.0.0.1` 回调地址用
4. 也可在「应用中心 → 已安装」里启动/停止

## 两个硬要求的实现方式（已实测）

### 1. 页内弹窗，不跳转

`app/ui/config` 里所有入口都是 `"type": "iframe"`，主入口用统一网关：

```json
"wildwork.main": {
  "type": "iframe", "protocol": "",
  "gatewayPrefix": "/app/wildwork", "gatewaySocket": "app.sock",
  "url": "/app/wildwork", "allUsers": true
}
```

- 飞牛网关把 `/app/wildwork/*` 转到 `$TRIM_APPDEST/app.sock`（unix socket），**保留前缀**并校验 NAS 登录态
- 主程序本身只说 HTTP，unix socket 由包内 `wwbridge` 建：
  `wwbridge $TRIM_APPDEST/app.sock /app/wildwork 127.0.0.1:5013 <LAN_IP>`
- 实测：`curl --unix-socket app.sock http://localhost/app/wildwork/` → **200**，标题 `wild-work 管理面板`；
  `/app/wildwork/v1/models` 带密钥 → **200 `{"data":[],"object":"list"}`**
- 原上游包里的「端口直连」入口（`port:7863` 的 iframe）**已移除**，避免 HTTPS 下的 mixed-content 白屏

### 2. IPv4 + IPv6 双栈

监听写 `0.0.0.0:5013`，该程序会把通配地址真正绑成双栈（`ss` 显示 `*:5013`）：

| 客户端 | 结果 |
|---|---|
| `127.0.0.1:5013`（IPv4 回环） | HTTP 200 |
| `[::1]:5013`（IPv6 回环） | HTTP 200 |
| `192.0.2.10:5013`（局域网 IPv4） | HTTP 200 |
| `[2001:db8::1d3]:5013`（局域网 IPv6） | HTTP 200 |

⚠️ 反面经验：写成 `[::]:5013` 反而**启动失败**（程序内部拼成 `:::5013`），不要改。

## 生命周期与运维

```bash
sudo appcenter-cli list | grep wildwork      # 查看状态
sudo appcenter-cli stop  wildwork
sudo appcenter-cli start wildwork
tail -f /vol6/@appdata/wildwork/wild-work.log   # 运行日志
```

- 控制脚本：`/vol6/@appcenter/wildwork/cmd/main`（start / stop / status）
- 停止会同时清掉 `app.sock`，启动时重建
- 升级：装新版本 fpk 即可，账号凭据与状态数据在数据目录里，**不会丢**

## API 使用

```bash
# IPv4
curl http://192.0.2.10:5013/v1/models -H "Authorization: Bearer WildWorkAPI"
# IPv6
curl "http://[2001:db8::1d3]:5013/v1/models" -H "Authorization: Bearer WildWorkAPI"
```

默认密钥 `WildWorkAPI`（上游默认值）。**建议改成自己的**：改
`/vol6/@appdata/wildwork/config.json` 与 `/vol6/@appcenter/wildwork/bin/config.json` 里的
`api_key`，或设环境变量 `WILDWORK_API_KEY`，然后重启应用。

## 风险提示

- 上游是**逆向第三方 IDE 额度**的工具（仓库带 `reverse-engineering` 标签），有 ToS/封号风险，且历史上被安全软件误报过
- 端口 5013 是**明文 HTTP 且无登录态**（只有 API Key）。要不要暴露到公网自行决定；
  局域网内使用最省心，远程建议只走飞牛统一网关入口（有 NAS 登录态）

## 从源码重建

```bash
cd <本目录>            # 需要 tpl/ payload/ assets/ build-fpk.sh
./build-fpk.sh 2.4.1 dist
```

`build-fpk.sh` 会：组装目录 → 生成 64/256 图标 → 写 manifest → 查 symlink/权限/JSON → `fnpack build` → 落盘。
换上游版本：把新二进制放到 `payload/wild-work`（需 `chmod +x`），版本号作为第 1 个参数。

---

生成时间：2026-09-23

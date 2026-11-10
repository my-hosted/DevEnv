---
status: accepted
---

# 在运行配置命令前注入项目级环境变量

同一 Project Record 下的多个 Run Configuration 常需要相同的前置环境初始化（例如 `source .env`、`direnv allow`、`nvm use` 或若干 `export`）。逐条配置重复书写既易漏也难维护，因此 DevEnv 允许项目保存一段可选的环境变量注入命令（Project Environment Injection），并在该项目关联的每次 Run Execution 中于配置命令前运行。

## 已确认的决定

- 注入命令保存在 Project Record 上，随项目记录持久化；空字符串或纯空白视为“未设置”，保存时去除首尾空白。
- 只作用于关联该项目的 Run Configuration。未关联项目、项目已删除或关联已失效的配置不注入。
- 注入在工作目录解析完成后、配置命令执行前运行，因此 `source .env` 等相对路径以该次执行的工作目录为基准；实现上把注入片段与配置命令拼接成同一段 Shell 脚本交给交互 Shell。
- 注入内容随启动冻结进本次 Run Execution（与 ADR-0012 的冻结启动请求一致）。启动、重启和批量启动使用同一条链路；重启会重新读取当时的项目注入命令。
- 注入只影响通过「启动／重启」发起的 Run Execution，不改变配置命令本身，也不改变项目要求扫描或运行建议。单独「打开终端」的交互 Shell 不会仅因项目设置而主动执行注入。
- 注入失败不单独阻断配置命令：脚本按顺序执行，注入的错误输出照常显示在终端，配置命令仍会尝试运行，退出码以最后的配置命令为准。

## 对现有模型的影响

Project Record 增加可选的注入命令字段，项目记录文档 schema 版本从 8 升到 9；旧文档缺少该字段时按“未设置”读取。Project Run Frozen Start Request 增加冻结的注入命令，Run Command Script 负责把注入与配置命令组合成最终发送给 Shell 的脚本；运行失败与执行记录仍只描述配置命令。

## 实现边界

注入只是用户显式填写并确认的 Shell 片段，DevEnv 不解析、不校验其语义，也不据此安装依赖或改变 Machine Environment。它以当前用户权限在配置的实际工作目录执行；UI 仅提供设置、编辑与清除入口，并在项目详情显示当前命令。

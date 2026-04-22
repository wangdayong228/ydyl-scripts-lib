# ydyl-scripts-lib

该目录用于沉淀可复用的脚本库（后续可独立为单独 repo 供其它仓库引用）。

当前三条顶层流水线都会依赖这里的公共脚本：

- `utils.sh`
- `pipeline_utils.sh`
- `pipeline_steps_lib.sh`
- `deploy_common.sh`

## 目录职责

### `utils.sh`

基础能力函数，主要包括：

- `require_command` / `require_commands`
  - 检查依赖 CLI 是否存在
- `require_file`
  - 检查文件是否存在
- `require_var`
  - 检查环境变量是否为空
- `run_with_retry`
  - 带重试执行命令
- `pm2_check_all_unerror`
  - 检查 PM2 是否有 `errored` 进程
- `ydyl_enable_traps`
  - 启用统一错误 trap 和堆栈打印

约定：

- 顶层流水线脚本应尽早 `source utils.sh`
- 在主流程初始化后调用 `ydyl_enable_traps`
- 若需要暂时抑制 trap，可参考 `cdk_pipe.sh` 中对 `YDYL_NO_TRAP=1` 的用法

### `pipeline_utils.sh`

状态化流水线的核心框架，主要包括：

- `pipeline_load_state`
  - 读取状态文件
- `save_state`
  - 将 `LAST_DONE_STEP` 和白名单变量写入状态文件
- `check_input_env_consistency`
  - 校验本次输入与历史状态是否一致
- `pipeline_parse_start_step`
  - 解析 `START_STEP`
- `run_step`
  - 通用步骤执行器

这部分决定了三条流水线的“可续跑”行为。

### `pipeline_steps_lib.sh`

提供可复用的公共 step 实现，目前主要包括：

- `step1_init_identities`
- `step2_fund_l1_accounts`
- `step5_fund_l2_accounts`
- `step7_deploy_counter_and_register_bridge`
- `step9_gen_accounts`
- `step10_collect_metadata`
- `step11_start_ydyl_console_service`
- `step12_check_pm2_unerror`

约定：

- 这里放“多条链都能复用”的 step
- 真正链类型专属的 step 仍然留在 `cdk_pipe.sh` / `op_pipe.sh` / `xjst_pipe.sh`

### `deploy_common.sh`

提供通用的 Kurtosis 部署骨架函数：`ydyl_kurtosis_deploy`（方案B：使用 `DEPLOY_*` 环境变量，避免长参数列表）。

### 命名规范（全量使用 `-`）

- `DEPLOY_NETWORK` 统一使用连字符风格：`eth`、`cfx-dev`、`cfx-test`、`gen` ...
- 部署 enclave 名由公共库推导：

```bash
ENCLAVE_NAME="${DEPLOY_L2_TYPE}-${DEPLOY_NETWORK}"
```

### 必需环境变量

- `DEPLOY_L2_TYPE`: `cdk` 或 `op`
- `DEPLOY_NETWORK`: `eth/cfx-dev/cfx-test/gen ...`
- `DEPLOY_TEMPLATE_FILE`: 模板路径
- `DEPLOY_RENDERED_ARGS_FILE`: 渲染后的 args 文件路径
- `DEPLOY_LOG_FILE`: 日志文件路径
- `DEPLOY_PACKAGE_LOCATOR`: Kurtosis package locator

### 可选环境变量

- `DEPLOY_UPDATE_NGINX_SCRIPT`: nginx 更新脚本路径（必填）
- `DEPLOY_DRYRUN`: `true/false`（默认 `false`）
- `DEPLOY_FORCE`: `true/false`（默认 `false`）

### 输出变量（export）

- `YDYL_DEPLOY_ENCLAVE_NAME`
- `YDYL_DEPLOY_STATUS`: `dryrun/ran/skipped`

### 用法示例

```bash
export DEPLOY_L2_TYPE=cdk
export DEPLOY_NETWORK=eth
export DEPLOY_TEMPLATE_FILE=/path/to/params.template.yml
export DEPLOY_RENDERED_ARGS_FILE=/path/to/params-eth.yml
export DEPLOY_LOG_FILE=/path/to/deploy-eth.log
export DEPLOY_PACKAGE_LOCATOR=github.com/Pana/kurtosis-cdk@<commit>
export DEPLOY_UPDATE_NGINX_SCRIPT=/path/to/update_nginx_ports.sh

source /path/to/ydyl-scripts-lib/deploy_common.sh
ydyl_kurtosis_deploy
```

## 状态管理约定

这是修改流水线时最容易漏掉的部分。

三条顶层流水线都会在各自脚本中定义：

- `STATE_FILE`
- `PERSIST_VARS`

其中：

- `STATE_FILE` 指向 `output/*.state`
- `PERSIST_VARS` 是允许持久化到状态文件的环境变量白名单

重要规则：

1. 只有加入 `PERSIST_VARS` 的变量，才会跨 step / 跨重跑保留
2. 如果新增变量需要被后续 step 使用，必须同步加入 `PERSIST_VARS`
3. 顶层脚本会在启动时调用 `check_input_env_consistency`
4. 如果本次显式输入与历史状态不一致，脚本会拒绝续跑
5. `DRYRUN=true` 时不会持久化状态

## 修改建议

修改公共库前，至少检查这几件事：

1. 这个改动是否同时影响 `cdk_pipe.sh`、`op_pipe.sh`、`xjst_pipe.sh`
2. 是否改变了状态文件结构或白名单变量语义
3. 是否会影响 `step7` 的 Counter / bridge 注册行为
4. 是否会影响 `step10` 产出的元数据字段
5. 是否会影响 PM2 健康检查和错误退出路径


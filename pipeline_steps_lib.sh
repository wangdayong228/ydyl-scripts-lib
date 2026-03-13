#!/bin/bash
# pipeline_steps_lib.sh
# 说明：
# - 本文件仅提供 step 函数定义，供 *pipe.sh 通过 source 引入。
# - step 函数会依赖调用方提前初始化的变量（如 DIR/STATE_FILE/PERSIST_VARS 等）
# - 本文件不在顶层执行任何逻辑，避免被 source 时产生副作用。

########################################
# STEP1: 生成助记词和关键私钥（只在缺失时生成）
########################################
step1_init_identities() {
	if [[ -z "${KURTOSIS_L1_PREALLOCATED_MNEMONIC:-}" ]]; then
		KURTOSIS_L1_PREALLOCATED_MNEMONIC=$(cast wallet new-mnemonic --json | jq -r '.mnemonic')
	fi

	if [[ -z "${CLAIM_SERVICE_PRIVATE_KEY:-}" ]]; then
		CLAIM_SERVICE_PRIVATE_KEY="0x$(openssl rand -hex 32)"
	fi

	# L2_PRIVATE_KEY 用途说明：
	# - L2 上部署 Counter 合约（bridge 注册流程依赖）
	# - ydyl-gen-accounts 的付款/部署账户（写入 ydyl-gen-accounts/.env 的 PRIVATE_KEY）
	if [[ -z "${L2_PRIVATE_KEY:-}" ]]; then
		L2_PRIVATE_KEY="0x$(openssl rand -hex 32)"
	fi

	# L2_ADDRESS 为 L2_PRIVATE_KEY 对应地址，用于后续在 STEP5 充值 L2 ETH，
	# 以支撑 Counter 部署与 ydyl-gen-accounts 批量交易等操作。
	if [[ -z "${L2_ADDRESS:-}" ]]; then
		L2_ADDRESS=$(cast wallet address --private-key "$L2_PRIVATE_KEY")
	fi
	if [[ "${L2_TYPE:-}" = "2" ]] && [[ -n "${L2_ADDRESS:-}" ]]; then
		# xjst 模式按约定把地址首位改为 1（仅改地址字符串，不改私钥）。
		L2_ADDRESS="$(printf '%s' "$L2_ADDRESS" | sed -E 's/^0x[0-9a-fA-F]/0x1/' | tr '[:upper:]' '[:lower:]')"
	fi

	export KURTOSIS_L1_PREALLOCATED_MNEMONIC CLAIM_SERVICE_PRIVATE_KEY L2_PRIVATE_KEY L2_ADDRESS

	echo "生成/加载身份："
	echo "KURTOSIS_L1_PREALLOCATED_MNEMONIC: $KURTOSIS_L1_PREALLOCATED_MNEMONIC"
	echo "CLAIM_SERVICE_PRIVATE_KEY: $CLAIM_SERVICE_PRIVATE_KEY"
	echo "L2_PRIVATE_KEY: $L2_PRIVATE_KEY"
	echo "L2_ADDRESS: $L2_ADDRESS"
	echo "L2_PRIVATE_KEY 用于：部署 L2 Counter 合约（bridge 注册流程）、以及 ydyl-gen-accounts 的付款/部署账户"
	echo "L2_ADDRESS 用于：接收 STEP5 的 L2 充值（为上述操作提供余额）"
}

########################################
# STEP2: 从 L1_VAULT_PRIVATE_KEY 转账 L1 ETH
########################################
step2_fund_l1_accounts() {
	if [[ -z "${KURTOSIS_L1_FUND_VAULT_ADDRESS:-}" ]]; then
		echo "错误: KURTOSIS_L1_FUND_VAULT_ADDRESS 未设置，请在上层 pipe 脚本中先生成/设置该地址" >&2
		return 1
	fi
	if [[ -z "${CLAIM_SERVICE_ADDRESS:-}" ]]; then
		CLAIM_SERVICE_ADDRESS=$(cast wallet address --private-key "$CLAIM_SERVICE_PRIVATE_KEY")
	fi
	if [[ -z "${L1_REGISTER_BRIDGE_ADDRESS:-}" ]]; then
		L1_REGISTER_BRIDGE_ADDRESS=$(cast wallet address --private-key "$L1_REGISTER_BRIDGE_PRIVATE_KEY")
	fi

	if [[ "${DRYRUN:-}" = "true" ]]; then
		echo "🔹 DRYRUN 模式: 转账 L1 ETH 给 KURTOSIS_L1_FUND_VAULT_ADDRESS ${KURTOSIS_L1_FUND_VAULT_ADDRESS}、CLAIM_SERVICE_PRIVATE_KEY ${CLAIM_SERVICE_ADDRESS} 和 L1_REGISTER_BRIDGE_ADDRESS ${L1_REGISTER_BRIDGE_ADDRESS} (DRYRUN 模式下不执行实际转账)"
	else
		echo "🔹 实际转账 L1 ETH 给 KURTOSIS_L1_FUND_VAULT_ADDRESS ${KURTOSIS_L1_FUND_VAULT_ADDRESS} 、CLAIM_SERVICE_PRIVATE_KEY ${CLAIM_SERVICE_ADDRESS} 和 L1_REGISTER_BRIDGE_ADDRESS ${L1_REGISTER_BRIDGE_ADDRESS}"
		# shellcheck disable=SC2153 # 相关变量由调用方（如 cdk_pipe.sh）负责初始化与校验
		run_with_retry 3 5 cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$L1_VAULT_PRIVATE_KEY" --value 5000ether "$KURTOSIS_L1_FUND_VAULT_ADDRESS" --rpc-timeout 60 || return 1
		run_with_retry 3 5 cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$L1_VAULT_PRIVATE_KEY" --value 1000ether "$CLAIM_SERVICE_ADDRESS" --rpc-timeout 60 || return 1
		run_with_retry 3 5 cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$L1_VAULT_PRIVATE_KEY" --value 1000ether "$L1_REGISTER_BRIDGE_ADDRESS" --rpc-timeout 60 || return 1
	fi
}

########################################
# STEP5: 给 L2_PRIVATE_KEY 和 CLAIM_SERVICE_PRIVATE_KEY 转账 L2 ETH
########################################
step5_fund_l2_accounts() {
	if [[ "${DRYRUN:-}" = "true" ]]; then
		echo "🔹 DRYRUN 模式: 转账 L2 ETH 给 L2_PRIVATE_KEY 和 CLAIM_SERVICE_PRIVATE_KEY (DRYRUN 模式下不执行实际转账)"
	else
		echo "🔹 实际转账 L2 ETH 给 L2_PRIVATE_KEY 和 CLAIM_SERVICE_PRIVATE_KEY"
		# 说明：这里给 L2_ADDRESS（由 L2_PRIVATE_KEY 推导）充值，主要用于后续 Counter 部署与 ydyl-gen-accounts 交易等。
		run_with_retry 3 5 cast send --legacy --rpc-url "$L2_RPC_URL" --private-key "$L2_VAULT_PRIVATE_KEY" --value 6000ether "$L2_ADDRESS" --rpc-timeout 60 || return 1
		run_with_retry 3 5 cast send --legacy --rpc-url "$L2_RPC_URL" --private-key "$L2_VAULT_PRIVATE_KEY" --value 1000ether "$CLAIM_SERVICE_ADDRESS" --rpc-timeout 60 || return 1
	fi
}

########################################
# STEP7: 部署 counter 合约并注册 bridge
########################################
step7_deploy_counter_and_register_bridge() {
	cd "$DIR"/zk-claim-service || return 1
	yarn
	PRIVATE_KEY=0x0000000000000000000000000000000000000000000000000000000000000000 npx hardhat compile

	if [[ -z "${COUNTER_BRIDGE_REGISTER_RESULT_FILE:-}" ]]; then
		COUNTER_BRIDGE_REGISTER_RESULT_FILE="$DIR"/output/counter-bridge-register-result-"$NETWORK".json
	fi

	node ./scripts/i_deployCounterAndRegisterBridge.js --out "$COUNTER_BRIDGE_REGISTER_RESULT_FILE"
}

########################################
# STEP9: 运行 ydyl-gen-accounts 生成账户
########################################
step9_gen_accounts() {
	cd "$DIR"/ydyl-gen-accounts || return 1
	echo "🔹 STEP9.1: 清理旧文件"
	npm i
	npm run clean

	echo "🔹 STEP9.2: 创建 .env 文件"
	# 说明：把 L2_PRIVATE_KEY 写入 ydyl-gen-accounts 的 PRIVATE_KEY，作为其付款/部署账户。
	cat >.env <<EOF
PRIVATE_KEY=$L2_PRIVATE_KEY
RPC=$L2_RPC_URL
EOF

	if [[ "${ENABLE_GEN_ACC:-}" = "false" ]]; then
		echo "🔹 跳过生成账户，因为 ENABLE_GEN_ACC 为 false"
		return 0
	fi

	echo "🔹 STEP9.3: 启动生成账户服务"
	npm run build
	npm run start -- --fundAmount 1000 --processes 1 --capacity 20000000
}

########################################
# STEP10: 收集元数据并保存
########################################
step10_collect_metadata() {
	if [[ -z "${COUNTER_BRIDGE_REGISTER_RESULT_FILE:-}" ]]; then
		COUNTER_BRIDGE_REGISTER_RESULT_FILE="$DIR"/output/counter-bridge-register-result-"$NETWORK".json
	fi

	L2_COUNTER_CONTRACT=$(jq -r '.counter' "$COUNTER_BRIDGE_REGISTER_RESULT_FILE")

	METADATA_FILE=$DIR/output/$ENCLAVE_NAME-meta.json
	export L2_RPC_URL L2_VAULT_PRIVATE_KEY L2_COUNTER_CONTRACT L2_TYPE
	# 说明：metadata 中的 L2_PRIVATE_KEY 对应本次部署所用的 L2 账户私钥：
	# - 用于部署 L2 Counter 合约（bridge 注册流程）
	# - 用于 ydyl-gen-accounts 的付款/部署账户
	jq -n 'env | { L2_TYPE, L1_VAULT_PRIVATE_KEY, L2_RPC_URL, L2_VAULT_PRIVATE_KEY, KURTOSIS_L1_PREALLOCATED_MNEMONIC, CLAIM_SERVICE_PRIVATE_KEY, L2_PRIVATE_KEY, L1_CHAIN_ID, L2_CHAIN_ID, L1_RPC_URL, L2_COUNTER_CONTRACT}' >"$METADATA_FILE"
	echo "文件已保存到 $METADATA_FILE"
}

########################################
# STEP11: 启动 ydyl-console-service 服务
########################################
step11_start_ydyl_console_service() {
	cd "$DIR"/ydyl-console-service || return 1
	cp config.sample.yaml config.yaml
	go build .
	pm2 restart ydyl-console-service || pm2 start ./ydyl-console-service --name ydyl-console-service
	echo "ydyl-console-service 服务已启动"
}

########################################
# STEP12: 检查 PM2 进程是否有失败
########################################
step12_check_pm2_unerror() {
	pm2_check_all_unerror
}

skip_step() {
	return 0
}

#!/usr/bin/env bash
# dev 들어오는 연결 정책(#39·#40) 실제 차단 시험. kind·EC2(k3s) 공통.
# 허용 표(tests/networkpolicy/expected.json)의 "보내는 쪽"마다 같은 이름표를 단 시험 Pod를 그 네임스페이스에 띄우고,
# dev의 실제 Pod IP:포트로 TCP 연결을 시도해 표와 비교한다(허용 = 연결 성공, 차단 = 실패).
# 리스너가 있는 포트만 본다(리스너가 없으면 허용이어도 실패하므로 구분이 안 된다). 나머지 조합은 정적 시험이 본다.
# 실패로 끝나는 경우: 받는 쪽 Pod 없음, 시험 Pod exec 실패, 결과 행 빠짐·중복·모르는 행, 표와 다름(tests/networkpolicy/probe_compare.py).
# 출발지 해석 주의: ingest-load 흉내 Pod는 EC2에서 ingest egress 정책도 같이 받아 '차단'이 ingress만의 증거는 아니다.
#
# 사용: scripts/netpol/probe.sh [--context <kubectl 컨텍스트>] [--scenario <expected.json allow 키>] [--keep]
# EKS: --context <context> --namespace <dev|prod> [--expected <table>] [--scenario baseline|metrics|alb|alb-metrics]
#   --keep: 시험 Pod를 지우지 않는다(손으로 더 볼 때). 지울 때: 아래 cleanup과 같은 명령.
# 시험 Pod: 이름표 ureka-netpol-probe=true, PSA restricted를 지킨다(비root·seccomp·capability 없음), 이미지는 dev chat 이미지(python).
# observability 네임스페이스가 없으면(kind) 만들고 끝나면 지운다. 이미 있으면(EC2) 시험 Pod만 지운다.
set -euo pipefail
# --namespace를 명시하면 EKS Deployment probe로 실행한다. 기존 EC2/kind 인자는 그대로 둔다.
for arg in "$@"; do
  if [ "$arg" = --namespace ]; then
    exec python3 "$(dirname "$0")/probe_eks.py" "$@"
  fi
done
cd "$(dirname "$0")/../.."

ctx=()
scenario="기본(관측 꺼짐)"
keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --context) ctx=(--context "$2"); shift 2 ;;
    --scenario) scenario="$2"; shift 2 ;;
    --keep) keep=1; shift ;;
    *) echo "모르는 인자: $1" >&2; exit 2 ;;
  esac
done
# EC2: sudo의 PATH에 /usr/local/bin(kubectl 링크)이 없을 수 있어 k3s kubectl로 대신한다.
if command -v kubectl >/dev/null 2>&1; then kc=(kubectl); elif command -v k3s >/dev/null 2>&1; then kc=(k3s kubectl); else echo "kubectl이 없다" >&2; exit 2; fi
k() { "${kc[@]}" ${ctx[@]+"${ctx[@]}"} "$@"; }
expected=tests/networkpolicy/expected.json
# 리스너가 있는 (받는 쪽, 포트). Mailpit 8025는 Pod 안 127.0.0.1에만 열려 있어 뺀다(port-forward 전용). 관측을 켠 환경이면 PROBE_TARGETS에 "ureka-auth:9091 ureka-content:9091"을 더한다.
targets="${PROBE_TARGETS:-ureka-frontend:8080 ureka-auth:8080 ureka-chat:8080 ureka-content:8080 ureka-ops:8080 ureka-recommend:8000 redis:6379 mailpit:1025}"

image="$(k -n dev get deploy ureka-chat -o jsonpath='{.spec.template.spec.containers[0].image}')"
cleanup() {
  [ "$keep" -eq 1 ] && { echo "시험 Pod를 남겼다(--keep)"; return; }
  for ns in $(python3 -c 'import json,sys;print(" ".join(sorted({s["namespace"] for s in json.load(open(sys.argv[1]))["sources"].values()})))' "$expected"); do
    k -n "$ns" delete pod -l ureka-netpol-probe=true --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  # 이 스크립트가 만든 observability(이름표 ureka-netpol-probe=true)만 지운다. EC2의 진짜 observability는 이름표가 없어 남는다.
  k delete namespace -l ureka-netpol-probe=true --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! k get namespace observability >/dev/null 2>&1; then
  k create namespace observability >/dev/null
  k label namespace observability pod-security.kubernetes.io/enforce=restricted ureka-netpol-probe=true >/dev/null
fi

# 보내는 쪽마다 시험 Pod 하나(이름: probe-<번호>)
pods="$(mktemp)"
python3 - "$expected" "$image" > "$pods" <<'PY'
import json, sys
exp = json.load(open(sys.argv[1], encoding="utf-8")); image = sys.argv[2]
for i, (name, s) in enumerate(exp["sources"].items()):
    labels = dict(s["labels"]); labels["ureka-netpol-probe"] = "true"
    pod = {"apiVersion": "v1", "kind": "Pod",
           "metadata": {"name": f"probe-{i}", "namespace": s["namespace"], "labels": labels,
                        "annotations": {"ureka/netpol-source": name}},
           "spec": {"automountServiceAccountToken": False, "restartPolicy": "Never", "terminationGracePeriodSeconds": 0,
                    "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001,
                                        "seccompProfile": {"type": "RuntimeDefault"}},
                    "containers": [{"name": "probe", "image": image, "imagePullPolicy": "IfNotPresent",
                                    "command": ["python", "-c", "import time; time.sleep(1800)"],
                                    "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}},
                                    "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                                                        "capabilities": {"drop": ["ALL"]}}}]}}
    print(json.dumps(pod))
PY
k apply -f "$pods" >/dev/null
rm -f "$pods"
for ns in $(python3 -c 'import json,sys;print(" ".join(sorted({s["namespace"] for s in json.load(open(sys.argv[1]))["sources"].values()})))' "$expected"); do
  k -n "$ns" wait pod -l ureka-netpol-probe=true --for=condition=Ready --timeout=120s >/dev/null
done

# 받는 쪽 Pod IP (Running인 첫 Pod)
pairs=()
for t in $targets; do
  name="${t%%:*}"; port="${t##*:}"
  ip="$(k -n dev get pod -l "app.kubernetes.io/name=${name},!ureka-netpol-probe" --field-selector=status.phase=Running -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
  # 없으면 이 받는 쪽의 결과 행이 생기지 않아 비교에서 "결과 없음"으로 실패한다.
  [ -n "$ip" ] || { echo "::error::받는 쪽 ${name} Pod 없음(Running)" >&2; continue; }
  pairs+=("${name}:${port}:${ip}")
done

results="$(mktemp)"
checker='import socket,sys,concurrent.futures as f
import time
# 막 뜬 Pod는 정책 엔진(kind kube-network-policies 등)이 알기 전까지 몇 초간 연결이 거부될 수 있다.
# DNS(나가는 연결은 막지 않음)가 될 때까지 기다린 뒤 시작하고, 실패는 3번까지 다시 해 본다(허용은 한 번 성공이면 확정).
for _ in range(60):
    try: socket.gethostbyname("kube-dns.kube-system.svc.cluster.local"); break
    except Exception: time.sleep(1)
def one(p):
    n,port,ip=p.split(":")
    for i in range(3):
        try:
            socket.create_connection((ip,int(port)),timeout=3).close(); return f"{n}:{port} 허용"
        except Exception as e:
            err=type(e).__name__; time.sleep(2)
    return f"{n}:{port} 차단 {err}"
with f.ThreadPoolExecutor(16) as ex:
    for r in ex.map(one,sys.argv[1:]): print(r)'
pids=()
while read -r ns pod src; do
  ( set -o pipefail; k -n "$ns" exec "$pod" -- python -c "$checker" ${pairs[@]+"${pairs[@]}"} | sed "s#^#${src} #" > "${results}.${pod}.${ns}" ) &
  pids+=("$!")
done < <(for ns in $(python3 -c 'import json,sys;print(" ".join(sorted({s["namespace"] for s in json.load(open(sys.argv[1]))["sources"].values()})))' "$expected"); do
  k -n "$ns" get pod -l ureka-netpol-probe=true -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.metadata.annotations.ureka/netpol-source}{"\n"}{end}'
done)
# 인자 없는 wait는 실패를 넘기지 않는다. 작업마다 종료 코드를 모은다.
exec_failures=0
for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || exec_failures=$((exec_failures + 1)); done
cat "${results}".*.* > "$results" 2>/dev/null || true
rm -f "${results}".*.*

status=0
python3 tests/networkpolicy/probe_compare.py "$expected" "$scenario" "$targets" "$results" "$exec_failures" || status=$?
rm -f "$results"
exit "$status"

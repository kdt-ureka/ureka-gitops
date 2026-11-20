# EC2 dev ingest 최초 적재 (수동 Job)

ureka-ingest `load-initial --with-embeddings`를 EC2 dev k3s에서 사람이 직접 돌리는 절차입니다. Argo CD가 자동으로 만들지 않습니다.
서버 명령은 EC2 안(SSM 셸, `cd ~/ureka-gitops`)에서 CN 담당이 실행합니다. 원본 CSV와 그 위치·링크는 Git·PR·채팅에 올리지 않습니다.

## 구성

| 것 | 내용 |
|---|---|
| 이미지 | ureka-ingest main `b57c76a`(ingest#20) CI `image-ref.json`의 ECR tag·digest. 레지스트리 주소는 `/etc/ureka/registry.env`에서 스크립트가 넣는다 |
| 원본 보관 | S3 적재 CSV 버킷(`infra/environments/ec2/ingest_bucket.tf`). 공개 차단·SSE-S3·버전 관리(이전 버전 30일 뒤 삭제). 올리기는 CN 담당 SSO만, EC2 호스트 역할은 `ingest-csv/` 읽기만. 버킷 이름은 Git에 없고 서버 `/etc/ureka/ingest.env`에만 둔다 |
| 입력 | PVC `ingest-input`(local-path 2Gi). 적재 Job은 읽기 전용으로 붙인다. dev는 PSA restricted라 hostPath를 못 쓴다 |
| 출력 | PVC `ingest-output`(1Gi)의 `<Job 이름>/quarantine.jsonl`. Job마다 폴더가 달라 앞 결과를 덮어쓰지 않는다 |
| 파일 배치 | `DATA_DIR=/work`(빈 임시 폴더)에 CSV 링크(→ `/input`)와 `output` 링크(→ `/out/<Job>`)를 만든다. 읽기 전용 폴더 안에 쓰기 볼륨을 겹쳐 붙이지 않는다(docs#86 재발 방지) |
| DB | Service `postgres`(RDS ExternalName), 계정 `content_db_ingest`(Secret `ureka-ingest-db`), `sslmode=require` |
| Gemini 키 | Secret `ureka-chat-ai`의 `AI_API_KEY`를 `GEMINI_API_KEY`로(팀 키, 원본 Secrets Manager `ureka/dev/chat-ai`). chat과 한도를 나눈다 |
| 통신 | NetworkPolicy: 적재 Pod는 들어오는 연결 없음, 나가는 연결은 DNS·RDS 5432(사설 서브넷)·외부 443(사설·메타데이터 대역 제외). 파일 Pod는 모두 막음 |
| 자원 | 적재 Job request 100m/256Mi, limit 1CPU/1Gi. 시험 run에서 실측해 조정 |
| 시간 제한 | 시험 1시간, 전체 14시간. `backoffLimit: 0`(자동 재실행 없음), 끝난 Job은 이틀 뒤 지워짐(결과 파일은 PVC에 남음) |

## 시작 전 확인

- **content 이미지가 V15 이상**: ingest는 `catalog.countries`에 없는 국가 코드를 가진 작품을 격리합니다. V15(국가 기준정보)가 없는 content(V14)에 적재하면 대부분 격리됩니다.
- **격리가 1건이라도 있으면 OTT가 반영되지 않습니다**: 작품 단계 격리는 OTT full snapshot을 `failed`로 만들고, 그러면 현재 OTT 상태가 바뀌지 않습니다. 검색 가능 조건에 OTT 제공이 들어 있어 **검색 가능 작품이 0건**으로 남습니다. 임베딩 격리는 OTT 반영을 막지 않지만 그 작품은 검색되지 않습니다. 격리된 작품만 다시 돌리는 run(`--content-id`)은 OTT를 최종화하지 않습니다.
- **Gemini 키 한도**: 작품 1건 = 임베딩 요청 1건(순차)입니다. 전체 약 2.9만 건이면 요청도 약 2.9만 건입니다. 키의 분당·일일 한도가 이보다 작으면 429가 이어져 격리가 늘거나 시간 제한에 걸립니다. 시작 전에 키 등급·한도를 확인합니다.
- **파일 이름**: ingest가 읽는 이름은 `01_공통_common_staging_v0_0_21.csv`, `02_movie_details_staging_v0_0_21.csv`, `03_tv_series_details_staging_v0_0_21.csv`입니다. 다른 버전 파일이면 ingest 코드가 먼저 바뀌어야 합니다(이름만 바꿔 넣지 않습니다).

## 실행 규칙

- 상태를 바꾸는 명령(`prepare`·`fetch`·`recv`·`store`·`run`·`cleanup`)은 서버 잠금(`/run/lock/ureka-ingest.lock`)으로 한 번에 하나만 돈다. 다른 명령이 돌고 있으면 바로 거절한다.
- 끝나지 않은 적재 Job(Pending 포함, Complete·Failed 조건이 없는 Job)이 있으면 `fetch`·`recv`·`store`·`run`을 거절한다. 적재 중 CSV가 바뀌거나 적재가 겹치지 않게 한다.
- `run`은 Job을 `create`로 만든다. 같은 분에 다시 실행해 이름이 겹치면 덮어쓰지 않고 실패한다(1분 뒤 다시).
- `quarantine`·`report` 출력과 격리 파일·로그에는 오류 문장(DB 오류에 행 값 일부가 섞일 수 있음)이 들어간다. 내부에서만 보고 Git·PR·채팅에 원문을 붙이지 않는다. 공유는 건수·오류 종류로 한다.

## 1. 준비 (서버)

```sh
sudo bash scripts/ec2/ingest.sh prepare
```

PVC 2개, NetworkPolicy 2개, 도구 ConfigMap `ingest-tools`, 파일 Pod `ingest-files`를 만듭니다.

## 2. CSV 옮기기

기본은 S3(2-A)입니다. S3를 못 쓸 때만 SSM 포트 포워딩(2-B)을 씁니다. 둘 다 서버 업로드 폴더(0700)에 받은 뒤 `store`로 PVC에 옮기고 sha256을 대조합니다.

### 2-0. 기준값

**내 PC: 기준값 기록** (CSV 폴더에서)

```sh
for f in 01_*.csv 02_*.csv 03_*.csv; do shasum -a 256 "$f"; python3 -c 'import csv,sys; csv.field_size_limit(1<<26); r=csv.reader(open(sys.argv[1],encoding="utf-8-sig",newline="")); next(r,None); print(sys.argv[1], sum(1 for _ in r), "rows")' "$f"; done
```

### 2-A. S3 (기본)

내 PC →(CN 담당 SSO) S3 `ingest-csv/` → 서버가 호스트 역할로 받기(읽기만) → 서버 업로드 폴더(0700) → PVC → 서버 사본 삭제. 적재 Pod는 IMDS가 막혀 S3에 접근하지 못하므로 받기는 서버(호스트)에서 합니다.

⓪ **처음 한 번: 버킷 만들기** (CN 담당이 `infra/environments/ec2`에서 `terraform plan` → 확인 → `terraform apply`). plan은 **추가 8(버킷과 설정 7 + 호스트 역할 읽기 정책 1), 변경 0, 삭제 0**이어야 합니다. 서버(EC2)는 바뀌지 않습니다.

① **처음 한 번: 서버에 버킷 이름 넣기** (`terraform apply` 뒤. 이름은 Git·PR·채팅에 쓰지 않습니다)

내 PC(`infra/environments/ec2` 폴더)에서 이름을 클립보드로 복사합니다.

```sh
terraform output -raw ingest_bucket_name | pbcopy
```

서버 셸에서 붙여 넣습니다(입력이 화면에 보이지 않고 셸 기록에도 남지 않음).

```sh
read -rsp '버킷 이름: ' b && echo && printf 'INGEST_BUCKET=%s\n' "$b" | sudo tee /etc/ureka/ingest.env >/dev/null && unset b && sudo chmod 0644 /etc/ureka/ingest.env
```

② **내 PC: 올리기** (`AWS_PROFILE=ureka-admin`. 먼저 `infra/environments/ec2`에서 `b="$(terraform output -raw ingest_bucket_name)"`, 그다음 CSV 폴더로 이동)

```sh
for f in 01_*.csv 02_*.csv 03_*.csv; do aws s3 cp "$f" "s3://$b/ingest-csv/$f" --checksum-algorithm SHA256 --only-show-errors; done
```

같은 이름으로 다시 올리면 이전 파일은 이전 버전으로 30일 남습니다. 세 파일이 모두 올라간 뒤에 서버에서 받고, 받는 동안 다시 올리지 않습니다. `ingest-csv/`는 Terraform `ingest_csv_prefix` 기본값입니다(바꾸면 서버 `INGEST_PREFIX`와 이 명령도 같이 바꿉니다).

③ **서버: 받기 → PVC로 옮기고 대조**

```sh
sudo bash scripts/ec2/ingest.sh fetch
sudo bash scripts/ec2/ingest.sh store
sudo bash scripts/ec2/ingest.sh stat
```

`fetch`가 보여 주는 sha256과 `stat`의 sha256·행 수가 2-0과 **세 파일 모두** 같은지 본 뒤에 `run`합니다. `fetch`는 시작할 때 이전에 받은 세 파일을 지우므로, 중간에 실패하면 `store`가 빠진 파일로 멈춥니다(다시 `fetch`). 오류 문장의 버킷 이름은 `<버킷>`으로 가려지지만 다른 AWS 오류 정보(ARN 등)는 그대로이니 내부에서만 보고 원문을 붙이지 않습니다.

### 2-B. SSM 포트 포워딩 (예비, AWS 변경 없음)

내 PC → (SSM 포트 포워딩) → 서버 `127.0.0.1:18090` 임시 수신기 → 서버 임시 폴더(0700) → PVC → 서버 사본 삭제. 보안 그룹·공인 포트를 열지 않습니다.

① **서버: 수신기 시작** (세 파일을 다 받으면 스스로 끝남)

```sh
sudo bash scripts/ec2/ingest.sh recv
```

② **내 PC 새 탭: 포트 포워딩** (`infra/environments/ec2` 폴더, `AWS_PROFILE` 설정)

```sh
aws ssm start-session --target "$(terraform output -raw instance_id)" --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["18090"],"localPortNumber":["18090"]}'
```

③ **내 PC 또 다른 탭: 보내기** (CSV 폴더에서. 경로는 파일 종류만 받는다)

```sh
curl -sS --fail -T 01_공통_common_staging_v0_0_21.csv http://127.0.0.1:18090/common
curl -sS --fail -T 02_movie_details_staging_v0_0_21.csv http://127.0.0.1:18090/movie
curl -sS --fail -T 03_tv_series_details_staging_v0_0_21.csv http://127.0.0.1:18090/tv
```

응답의 sha256이 2-0과 같아야 합니다. 끝나면 ② 탭을 닫습니다. 수신기는 연결이 120초 동안 멈추면 그 요청을 버리고 다음 연결을 받습니다(그 파일만 다시 보내기).

④ **서버: PVC로 옮기고 대조**

```sh
sudo bash scripts/ec2/ingest.sh store
sudo bash scripts/ec2/ingest.sh stat
```

`store`는 서버 사본과 PVC 파일의 sha256이 셋 다 같을 때만 그 세 파일을 지웁니다(업로드 폴더의 다른 파일은 건드리지 않음). `stat`의 sha256·행 수가 2-0과 같은지 봅니다.

## 3. 시험 적재 (기본 100건)

```sh
sudo bash scripts/ec2/ingest.sh run sample        # 공통 CSV 앞쪽에서 상세 행이 있는 movie 50·tv 50
sudo bash scripts/ec2/ingest.sh progress          # 몇 분마다
sudo bash scripts/ec2/ingest.sh quarantine        # 끝난 뒤
sudo bash scripts/ec2/ingest.sh report
```

시험 run은 `--content-id`로 고른 작품만 처리합니다. 상세 CSV 전체를 읽으므로 메모리는 전체 run과 비슷하게 잡힙니다. OTT full snapshot이 아니라서 현재 OTT·검색 가능 상태는 바뀌지 않습니다(정상).

기록할 것:

| 항목 | 보는 곳 |
|---|---|
| 걸린 시간 | `progress`의 시작·끝(Job startTime·completionTime), 로그 첫·끝 줄 |
| 적재·격리 건수 | 로그 마지막 줄 `적재 완료: N건, 격리 M건` |
| 429 | `quarantine`의 `http_error HTTP 429` 건수(재시도 후 최종 실패만). 재시도 중 대기는 기록되지 않으니 건당 평균 시간으로 함께 본다 |
| 토큰 | ingest가 기록하지 않음. Google AI Studio 사용량 화면에서 키 주인이 확인 |
| Pod 자원 | `progress`의 `kubectl top`(실행 중일 때). 메모리가 limit 1Gi에 가까우면 전체 run 전에 올린다 |
| RDS 자원 | AWS 콘솔 RDS CloudWatch(CPU·여유 메모리·연결 수) |
| 전체 시간 추정 | (시험 시간 / 100) × 전체 행 수. 429가 있었으면 한도로 다시 계산 |

## 4. 전체 적재

시험 결과에 격리가 없고 시간 추정이 14시간 안이면:

```sh
sudo bash scripts/ec2/ingest.sh run full
sudo bash scripts/ec2/ingest.sh progress
```

밤새 볼 것: `progress`의 작품·활성 임베딩 수가 늘어나는지, 격리 줄 수, Pod 메모리, Job이 아직 실행 중인지.

## 5. 끝난 뒤 확인

```sh
sudo bash scripts/ec2/ingest.sh progress <Job 이름>
sudo bash scripts/ec2/ingest.sh quarantine <Job 이름>
sudo bash scripts/ec2/ingest.sh report
```

`report`가 보여 주는 것(실행 기록의 실패 이유 앞 100자 포함, 내부에서만 볼 것): 작품 수(media_type·content_type별), 검색문서 상태별 수, 활성 임베딩 수/작품 수(임베딩 비율), OTT 현재 제공 작품 수, 검색 가능 작품 수, 최근 실행 기록 10건(상태·건수·실패 이유).

- Job이 `Failed`여도 격리 때문일 수 있습니다(격리가 있으면 ingest가 종료 코드 1). 로그 마지막 줄과 `quarantine`으로 판단합니다.
- OTT 실행 기록이 `failed`면 현재 OTT가 반영되지 않은 상태입니다(위 "시작 전 확인").
- 자동 최종화 뒤 응답을 확인하지 못했을 때만 `finalize-ott --run-id <RUN_ID>`를 따로 실행합니다(이 스크립트에는 없음).

## 6. 정리

```sh
sudo bash scripts/ec2/ingest.sh cleanup     # 파일 Pod만 지운다
```

PVC(원본 CSV·격리 결과)는 남깁니다. 지울 때는 `sudo k3s kubectl -n dev delete pvc ingest-input ingest-output`를 따로 판단해서 실행합니다.

## 검증

`bash scripts/test-ec2-ingest.sh`(CI Helm 워크플로): 가짜 kubectl·flock·aws로 prepare·fetch(버킷 이름 형식·출력에서 가림·0600·실패 시 .part 없음)·store(sha256 대조·세 파일만 삭제)·run sample/full 렌더링·잠금·끝나지 않은 Job(Pending·SuccessCriteriaMet만) 때 recv·store·run 거절·같은 이름 Job 거절·Job 이름 검사·report·격리 요약·임시 수신기(경로 고정, 0700/0600, 멈춘 연결 시간 초과)를 봅니다. 실제 클러스터·RDS·S3·Gemini 호출은 하지 않습니다. 버킷·역할 권한은 `infra/environments/ec2/tests/plan.tftest.hcl`(mock provider)이 봅니다.

## 격리 재처리·OTT 확정

0. 서버 gitops를 받은 뒤(`git pull --ff-only`) `prepare`로 도구 ConfigMap을 갱신한다. `retry`가 쓰는 `csvtool.py ids`가 여기 들어 있다. 파일 Pod가 하루 지나 끝났으면 아래처럼 `cleanup` 뒤 `prepare`.
1. 먼저 격리 원인을 정정한다(예: 인물 값 충돌이면 ingest 담당이 승인한 방식으로 CN 담당이 서버에서만 UPDATE). 정정 값은 Git·문서에 남기지 않는다.
2. `sudo bash scripts/ec2/ingest.sh run retry <격리가 난 Job>`으로 격리 작품만 임베딩 포함 재처리한다(예: `ingest-load-full-20261119-0652`). UUID 중복은 제거하고 최대 500건까지 허용한다.
3. `sudo bash scripts/ec2/ingest.sh quarantine <새 retry Job>`으로 격리 0건을 확인한다. 임베딩 timeout은 자동 재시도가 없으므로 남으면 그 retry Job을 대상으로 `run retry <Job>`을 한 번 더 실행한다.
4. `sudo bash scripts/ec2/ingest.sh run full --no-embeddings`로 전체 OTT를 확정한다.
5. `sudo bash scripts/ec2/ingest.sh report`에서 OTT 현재 제공·검색 가능 작품 수를 확인한다.

`--no-embeddings`는 full 전용이며 새 작품의 임베딩을 만들지 않으므로 retry를 먼저 완료한다. 기존 임베딩은 유지한다. 임베딩 실패 자체는 OTT 확정을 막지 않지만 작품 적재 실패는 막는다. retry는 `--content-id`를 사용하므로 OTT 전체 상태를 확정하지 않는다. 일반 `run full`은 계속 임베딩을 생성한다.

파일 Pod는 `activeDeadlineSeconds: 86400`으로 하루 뒤 종료된다. prepare에서 “이미 있습니다”가 나와도 Ready가 되지 않으면 `sudo bash scripts/ec2/ingest.sh cleanup` 뒤 `sudo bash scripts/ec2/ingest.sh prepare`를 실행한다. PVC와 Job 결과는 유지된다.

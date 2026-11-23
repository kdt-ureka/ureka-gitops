# EKS prod content 지식 데이터 복사 (dev → prod)

`content_db`에서 이미 적재·검증한 작품·검색문서·임베딩·OTT·적재 기록을 같은 RDS의 `content_db_prod`로 **한 번 복사**한다. Gemini를 호출하거나 CSV를 다시 적재하지 않는다. 기본 구조·함수·역할·권한은 prod content 앱의 Flyway와 #95 bootstrap이 만든다.

이 문서의 AWS·클러스터 실행 절차는 **아직 실행하지 않았다**. CN 담당이 검토·승인된 운영 시간에만 실행한다. 공개 트래픽을 받기 전의 빈 prod 지식베이스가 대상이며, 이미 쓰고 있는 prod 데이터 교체 도구가 아니다.

## 선행 순서

1. #95 prod 비밀 시드·논리 DB bootstrap 완료. 기존 dev 계정/비밀번호를 재발급하지 않는다.
2. prod ESO/ExternalSecret이 준비된 뒤 prod content 앱을 기동해 Flyway가 스키마를 만들게 한다. dev와 prod에 **동일한 content migration 버전**이 적용돼야 한다. 현재 도구는 검토된 V18~V20만 받는다. V21 이상이면 정책·보고 쿼리·FK/트리거 검증을 다시 검토한다.
3. 복사 시간 동안 dev ingest·매핑 변경과 prod 공개/관리자 데이터 변경을 중지한다. 도구는 source 28개 표에 SHARE 잠금을 유지해 쓰기·DDL을 막고 읽기는 허용한다. source의 사용자 검색 기록 쓰기도 잠시 대기할 수 있으므로 팀에 유지보수 시간을 알린다. 5초 내 잠금을 얻지 못하면 중단한다. prod에서는 같은 표에 ACCESS EXCLUSIVE 잠금을 잡아 복사 중 읽기·쓰기를 막는다.
4. 로컬의 `infra/environments/data`가 승인된 backend/default workspace로 초기화돼 있어야 한다. 마스터 비밀 ARN·엔드포인트는 Terraform output에서만 읽고 값은 출력하지 않는다.
5. CN SSO는 EKS 대상 확인, prod Lease·Job·Pod·Secret·ConfigMap 조작 및 RDS 관리 비밀 읽기 권한이 필요하다. ESO 리더 IRSA에 마스터 권한을 추가하지 않는다. RDS 마스터의 SET 권한과 대상 스키마 접근은 실제 첫 가동에서 확인한다.

```bash
# 운영 PC의 gitops 저장소에서. 승인 계정 환경 변수는 기존 EKS 운영 절차대로 입력(값을 공유하지 않음).
python3 scripts/eks/copy_prod_content.py check --profile ureka-admin
```

`check`는 계정/EKS/context·prod restricted·data output·파일 형식·공유 Lease를 확인할 뿐이다. **마스터 비밀을 읽지 않고 DB도 접속하지 않으므로**, Flyway/빈 표를 검사했다는 뜻이 아니다. 실제 DB 검사는 아래 `apply`가 만든 Job의 COPY 이전 단계에서 수행한다.

```bash
python3 scripts/eks/copy_prod_content.py apply --profile ureka-admin --confirm-env prod
```

Job은 최대 20분, 운영 도구는 최대 21분 기다린다. Quota 여유(추가 Pod 1개, request 100m/128Mi, limit 1CPU/512Mi)와 노드 임시 공간 2Gi를 확인한다. Job은 restricted(UID/GID/fsGroup 999, seccomp, capability 제거, 읽기 전용 root), 데이터 파일은 Job의 2Gi emptyDir에만 두고 종료 시 지운다. 실제 데이터 크기/시간은 아직 측정하지 않았다. 공간 부족/시간 초과 시 자동 재실행하지 않는다.

## 시작 전 검사와 원자성

- DB명은 `content_db` → `content_db_prod`로 코드에 고정되어 있고 둘 다 같은 PGHOST를 쓴다. 임의 DB명/다른 서버를 인자로 받지 않는다.
- source(`content_db`)도 같은 마스터로 접속한다. 원본 고정용 SHARE 잠금은 SELECT만 허용된 읽기 전용 계정이나 읽기 전용 트랜잭션에서 사용할 수 없기 때문이다. source 쪽 SQL은 TEMP 표·잠금·조회뿐이며 원본의 영구 표에는 쓰기 SQL을 실행하지 않는다.
- catalog·rag·ingest의 실제 표 목록이 아래 28개와 정확히 같아야 한다. 새 표·빠진 표·Flyway history 위치 변경은 중단한다.
- Flyway 최신 성공 버전뿐 아니라 installed_rank/version/type/checksum/success 전체 체인을 비교하고 실패 이력이 있으면 중단한다. 설치자·설치 시각은 환경마다 달라 비교하지 않는다.
- 양쪽 컬럼 구성·타입·NOT NULL·identity/generated 속성 및 제외한 기준 표 값도 대조한다. 기준 표의 `created_at`/`updated_at`만 비교에서 제외한다. 다른 값/추가 매핑/운영자가 변경한 정책이 다르면 **조용히 덮거나 건너뛰지 않고 중단**한다. 담당자와 승인된 migration/기준 데이터 정합 작업을 먼저 한다.
- 복사 대상 15개 표 중 하나라도 prod에 행이 있으면 중단한다. 원본 작품이 0건이거나 ingestion_runs에 running 기록이 있어도 중단한다.
- `pg_dump --data-only --no-owner --no-privileges`에 **명시적 표 allowlist**와 그 표에 종속된 identity sequence 3개만 넣는다. 스키마/함수/권한/소유자/역할/large object는 복사하지 않는다. `pg_dumpall`, `--clean`은 쓰지 않는다.
- 대상 표 잠금·빈 표 재확인·동일 metadata 재확인·데이터 restore·FK/활성 임베딩 검사·4개 보고 그룹 비교를 **하나의 prod 트랜잭션**에서 수행하고 일치한 뒤 COMMIT한다. COMMIT 전 1~5단계에서 실패하면 prod 표 행은 변경되지 않거나 해당 트랜잭션이 롤백된다. 6단계는 COMMIT 후 숫자 출력이므로 실패해도 이미 복사된 행은 남는다. PostgreSQL sequence의 `setval`은 롤백되지 않을 수 있어 실패 후 sequence 숫자가 앞서갈 수 있다(행 덮어쓰기는 하지 않음).

### FK·트리거 방식

FK 순서/지연 제약 및 원래 임베딩 활성 상태를 보존하기 위해 마스터 연결의 **그 트랜잭션 안에서만** `SET LOCAL session_replication_role=replica`를 사용한다. RDS 설정/권한이 이를 허용하지 않으면 COPY 전에 실패한다. 일반 앱·ESO 계정에 새 권한을 주거나 cluster 전체 parameter를 바꾸지 않는다. 같은 연결에서 origin으로 복귀한 뒤 다음을 직접 검사한다.

- 복사 표의 모든 실제 FK: composite key/NULL(MATCH SIMPLE)을 고려한 parent 누락 anti-join. 다른 MATCH 방식이 나오면 중단.
- V12의 콘텐츠당 활성 임베딩 1개 규칙. 귀속 불변 UPDATE 트리거는 이 INSERT/COPY 작업에 해당하지 않는다.
- PK/UNIQUE/NOT NULL/CHECK는 replica에서도 그대로 검사된다. V18 매핑 상태 표는 복사하지 않으며 seed 대조로 같은 상태를 요구한다.

`log_statement=none`, `log_min_error_statement=panic`을 세션 시작 옵션으로 요구한다. 허용되지 않는 권한/설정에서는 시작 실패로 멈춘다. psql/pg_dump 원문·오류·덤프는 Job private 임시 파일로만 받고 일반 Job 로그에는 단계 번호와 숫자 보고만 출력한다. 실제 RDS의 마스터는 완전한 PostgreSQL 슈퍼유저가 아니므로, 로컬 비슈퍼유저+명시적 SET/표 권한 시험을 실제 RDS 검증으로 대신하지 않는다.

## 제외 표와 migration 근거

검토한 content 소스: main `9d9c1ccb9367d5775feb9bfda54d9290a84dcb50`, V1~V20. 도구는 양쪽 V18~20의 동일 이력만 허용한다.

| 제외 표 | 이유·근거 |
|---|---|
| `catalog.flyway_schema_history` | prod Flyway의 실제 실행 이력 유지. 비교만 하고 복사하지 않음 |
| `catalog.ott_providers` | V4 seed, V8 이름/구조 전환. OTT 기준 ID·정책은 prod migration 유지 |
| `catalog.preference_options` | V4 CONTENT_TYPE/장르/시대/상황/분위기 seed |
| `catalog.genres`, `catalog.preference_option_genres` | V13 확정 장르/선택지 매핑 seed |
| `catalog.countries` | V15 국가 기준 seed |
| `catalog.mapping_versions` | V14 genre-map-v1 seed, V18 is_current 전환 |
| `catalog.mapping_group_rules`, `catalog.mapping_genre_rules` | V16 버전별 고정 매핑 seed |
| `rag.rerank_policies` | V14 rag-rerank-v1, V19 rag-rerank-v2 seed. prod 함수와 맞는 정책 유지 |
| `catalog.recent_searches` | V1/V10 사용자 ID·검색 문장·정렬 sequence. **사용자 정보가 있어 제외** |
| `catalog.search_daily_counts` | V3/V10 검색 문장·횟수. dev 시험 활동을 prod로 옮기지 않음 |
| `catalog.subject_cleanup_receipts` | V5 탈퇴/사용자 정리 수신 기록. 지식 데이터가 아니므로 제외 |

요청서의 “content에는 사용자 개인정보가 없음”과 달리 사용자 관련 표가 실제로 존재한다. 따라서 세 스키마를 통째로 dump하지 않고 지식 데이터만 명시적으로 고른다. 과거 watch_activities/ignored_contents/idempotency_keys는 V3에서, content_people은 V7에서, content_watch_providers는 V8에서, content_videos는 V11에서 삭제돼 최종 allowlist에 없다.

복사 표 15개:

- catalog: collections, contents, content_external_ids, movie_details, tv_series_details, people, content_credits, content_genres, content_countries, content_alternative_titles, content_ott_availability
- rag: content_search_documents, content_embeddings
- ingest: ingestion_runs, ingestion_ott_observations

## 복사 후 숫자 대조

Job은 복사 전 고정한 source와 commit 전 prod에서 아래 4종 보고를 비교한다. 모든 복사 표의 행 수도 추가로 비교한다. 비교용 fingerprint에는 실제 모델명/문서 형식/상태와 최근 실행 20건 전체 행이 포함되지만 원문은 출력하지 않는다.

Job 로그 출력의 `copy source`와 `copy prod` 아래 숫자들이 같아야 한다.

| 로그 종류 | 숫자 열 |
|---|---|
| `copy contents` | media_type 코드(1 movie, 2 tv), 전체 수, 검색 가능 수 |
| `copy documents` | 상태 코드, 수. 1 pending / 2 processing / 3 completed / 4 failed / 5 retryable / 6 excluded |
| `copy embeddings` | 모델·버전·형식·상태 정렬 그룹 번호, embedding_version, 그룹 수, 활성 수. 원래 그룹 키도 내부 비교에 포함 |
| `copy runs` | 최신 순 run_id, item_count(NULL은 -1), 상태 코드(1 running / 2 completed / 3 failed / 4 cancelled), full_snapshot(0/1). 최근 20건 |

마지막 `copy ok`와 운영 도구의 **정리 확인**까지 확인한다. 문서의 과거 예상 건수를 성공 조건으로 박아 두지 않고, 복사 시점의 고정된 dev와 prod가 같은지 검사한다.

`copy failed N`의 단계: 1 source 잠금·접속 / 2 Flyway·schema·seed 대조 / 3 빈 대상·진행 중 적재·표/sequence 확인 / 4 dump / 5 잠금 안 재검사·restore·FK·보고 비교 / 6 완료 숫자 출력. 오류 원문/덤프를 채팅이나 PR에 붙이지 않는다. 자동으로 재시도하거나 덮어쓰지 않는다.

**6단계 실패는 prod COMMIT 이후이므로 데이터는 이미 들어가 있다.** 복사 도구를 재실행하면 빈 표 검사로 막히므로 재실행하지 말고, source/prod 숫자만 내부에서 수동 조회해 대조한다. 복사 데이터 초기화나 재복사를 자동으로 진행하지 않는다.

## 잠금·임시 자격 정리·복구

#95와 **같은 prod Lease `db-bootstrap-prod-lock`**을 공유한다. 잠금 획득 전 마스터 비밀을 읽거나 잔여물을 삭제하지 않는다. bootstrap과 copy는 동시에 실행할 수 없다. 복사 자원은 `content-copy-prod` Job/ConfigMap, `content-copy-prod-master` Secret, `ureka.io/bootstrap-run=<run>` Pod다. bootstrap의 다른 이름 자원은 지우지 않는다.

종료 정리는 자기 실행 표시의 Job→Pod→Secret→ConfigMap 순이다. 성공·실패·Ctrl+C/SIGTERM 모두 정리를 시도한다. 정리 실패는 다른 오류보다 우선하여 **3**을 반환하고, 마스터 자격/실행 Job이 남을 수 있으므로 **공유 Lease도 유지**한다. 정상 정리 후 일반 실패는 1, 중단은 130이다. 프로세스가 강제 종료되거나 클러스터가 불통이면 자동 정리가 불가능하다.

복구는 담당자가 이전 실행/DB 세션이 실제로 끝났음을 먼저 확인한 다음에만 한다. Job deadline 20분/TTL 10분은 Secret 삭제 안전망이 아니다. `--recover-stale-lock`은 30분 경과와 수동 확인을 함께 요구한다. **#95 bootstrap 쪽으로 복구할 때도 copy Job/Pod/마스터 Secret이 남지 않았는지 별도로 확인**한다(bootstrap은 copy 이름 자원을 정리하지 않음). 다음 복사 실행의 시작 정리는 공유 잠금을 확보한 뒤 이전 copy 잔여물만 삭제하고, 삭제 확인 전에는 새 자격을 읽지 않는다.

```bash
# 내부 운영 화면에서만 조회. Secret -o yaml/json, Job 전체 로그·덤프는 공유하지 않는다.
kubectl --context "$EKS_CONTEXT" -n prod get lease db-bootstrap-prod-lock
kubectl --context "$EKS_CONTEXT" -n prod get job content-copy-prod
kubectl --context "$EKS_CONTEXT" -n prod get pod -l job-name=content-copy-prod
kubectl --context "$EKS_CONTEXT" -n prod get secret content-copy-prod-master
```

정리가 실패한 경우에는 이름·실행 표시·Lease holder를 내부에서 대조해 해당 실행만 삭제한 뒤 get에서 NotFound/빈 Pod 목록을 확인한다. 운영 중인 다른 실행의 Lease나 자원을 지우지 않는다.

## 다시 복사하려면: 별도 초기화 절차 (자동 실행 없음)

복사 도구에는 `--force`·`--truncate`·덮어쓰기 옵션이 없다. **1~5단계 실패는 prod 표 행 미변경 또는 트랜잭션 롤백, 6단계 실패는 이미 COMMIT된 상태**로 구분한다. 6단계에서는 재실행하지 말고 source/prod 숫자를 내부에서 수동 대조한다. 이미 commit된 데이터를 초기화해 다시 복사하려면 아래 **별도 승인**이 필요하다.

1. prod 공개/쓰기를 중단하고 영향 범위·백업/복구 지점을 확인한다. 이미 사용자 활동이 있는 prod라면 단순 재복사 대신 별도 데이터 변경 계획을 작성한다.
2. source와 prod Flyway/seed 상태를 다시 확인하고, 위 15개 지식 표만 초기화하는 SQL을 검토한다. 전체 DB DROP, schema DROP, `TRUNCATE ... CASCADE`는 쓰지 않는다.
3. #95/copy 실행이 없는 상태에서 같은 공유 Lease를 확보하는 **별도 유지보수 Job**을 승인한다. 그 Job의 단일 트랜잭션에서 지식 표 15개 전체를 명시적으로 `TRUNCATE <15개 표 목록> RESTART IDENTITY`하고, 다른 참조가 있으면 CASCADE로 우회하지 않고 중단한다. 이 문서는 초기화 Job을 자동 생성하지 않는다.
4. 지식 표 15개가 모두 0건이고 seed/사용자 관련 표는 그대로인지 확인한 뒤 임시 자격·Job·Lease를 정리한다.
5. 다시 이 복사 도구의 check→apply를 실행하고 숫자 대조한다. 초기화 승인이 없으면 기존 prod를 그대로 보존한다.

## 로컬 검증

```bash
python3 -m unittest discover -s tests/eks -p 'test_copy_prod_content.py' -v
# 내용이 검토된 content 저장소의 V18~V20 migration 폴더를 지정. 실제 AWS/EKS를 사용하지 않음.
python3 scripts/test-prod-content-copy.py --migrations <content-checkout>/src/main/resources/db/migration
```

실제 content V1~V20을 임시 PostgreSQL 18+pgvector 컨테이너에 적용한 합성 데이터 시험으로 정상 복사·사용자 이력 제외·identity sequence·비어있지 않은 대상·버전 불일치·seed 차이·CHECK 오류 전부 롤백·깨진 FK·진행 중 적재를 검증한다. 진단은 로컬 임시 시험 폴더에만 두고 컨테이너는 finally에서 삭제한다. RDS 고유 권한/네트워크/TLS·실제 29,940건 성능·EKS Quota·Pod 삭제를 검증했다는 뜻은 아니다.

참고: [PostgreSQL 18 pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html), [session_replication_role](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-SESSION-REPLICATION-ROLE), [RDS PostgreSQL parameters](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Parameters.html), [RDS master 권한](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Roles.rds_superuser.html).
